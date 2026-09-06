//! `pg_sys::FdwRoutine` plumbing — the FDW boundary (PRD-7 §6 step 7.1).
//!
//! ADR-002 (amended): the FDW routines are implemented directly on pgrx
//! 0.19.2's `pg_sys::FdwRoutine`, mirroring supabase-wrappers' architecture as
//! our own internal API (the `ForeignDataWrapper`-shaped traits live in
//! `tables/mod.rs`). This module is the **only** place `pg_sys` meets the
//! FDW: everything below the planner/executor callbacks — qual extraction,
//! slot filling, option/credential resolution — is handed to safe code as
//! plain Rust ([`Qual`], [`Cell`], [`ScanContext`]).
//!
//! ## Wiring
//!
//! * Planner: `GetForeignRelSize` (estimate, no I/O), `GetForeignPaths` (one
//!   sequential path), `GetForeignPlan` (split `scan_clauses` into pushed
//!   quals — serialized as one `makeString` JSON blob in `fdw_private` — and
//!   local clauses left for Postgres to re-check; `make_foreignscan`).
//! * Scan: `Begin`/`Iterate`/`ReScan`/`End` route through the resolved
//!   target's handler — the registry entry's `ForeignTable` (PRD-7), or the
//!   per-tool handler for generated `tool_<name>` tables (PRD-8 §4.2); the
//!   cursor lives in `node->fdw_state` and `end_scan` is `Drop`.
//! * Modify: `Plan`/`Begin`/`Exec` insert via the handler's `begin_modify`
//!   session (`tool_calls`, and every generated per-tool table); UPDATE/DELETE
//!   raise `0A000` (FR-7.12 / FR-8's universal-INSERT rule).
//! * `ImportForeignSchema` validates the remote schema name (§4.11: anything
//!   but `mcp` is `3F000`) and delegates DDL generation to `import.rs`.
//!
//! ## Table identity
//!
//! A foreign table resolves to a registry entry by its **relation name**
//! (`pg_class.relname` must equal the canonical table name from
//! `IMPORT FOREIGN SCHEMA`), or — failing that — to the per-tool handler by
//! its `tool` table option (PRD-8 §4.5 rule 7; the generated `tool_<name>`
//! objects). A foreign table with neither raises `0A000` — we never guess.
//!
//! ## Safety notes
//!
//! * `#[pg_guard]` on every `extern "C-unwind"` callback converts Rust panics
//!   into PostgreSQL errors; `McpError::raise`/`raise_ctx` longjmp out via
//!   `ereport`.
//! * The `FdwRoutine` is palloc'd in `TopMemoryContext`: the relcache caches
//!   the handler result across statements and memory contexts, so a
//!   statement-scoped allocation would dangle.
//! * Scan rows fill the executor's `ss_ScanTupleSlot` (`ExecInitScan` already
//!   initialized it with the foreign table's descriptor; `TTSOpsMinimalTuple`
//!   semantics), exactly as `postgres_fdw` does.

use crate::errors::McpError;
use crate::import::{self, TableFilter};
use crate::quals::{FdwPrivate, ParamQual, Qual};
use crate::session;
use crate::tables::{
    self, per_tool, Cell, InsertRow, ModifyContext, Row, ScanContext, TableContext, TableSpec,
};
use pgrx::pg_sys;
use pgrx::prelude::*;
use serde_json::Value as Json;
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int, c_void};
use std::ptr;

// ── handler ──────────────────────────────────────────────────────────────────

/// `mcp_fdw` handler: builds the `FdwRoutine`. Registered by the hand-written
/// SQL in `lib.rs` (`LANGUAGE C STRICT`); the SQL-visible wrapper must be
/// strict so `fcinfo` is never NULL here.
#[pg_guard]
#[no_mangle]
pub extern "C-unwind" fn mcp_fdw_handler(_fcinfo: pg_sys::FunctionCallInfo) -> pg_sys::Datum {
    // The relcache stores the returned routine beyond the current memory
    // context, so it must live in TopMemoryContext (see module docs).
    let routine = unsafe {
        let prev = pg_sys::MemoryContextSwitchTo(pg_sys::TopMemoryContext);
        let raw =
            pg_sys::palloc0(std::mem::size_of::<pg_sys::FdwRoutine>()) as *mut pg_sys::FdwRoutine;
        pg_sys::MemoryContextSwitchTo(prev);
        (*raw).type_ = pg_sys::NodeTag::T_FdwRoutine;
        raw
    };

    unsafe {
        (*routine).GetForeignRelSize = Some(get_foreign_rel_size);
        (*routine).GetForeignPaths = Some(get_foreign_paths);
        (*routine).GetForeignPlan = Some(get_foreign_plan);
        (*routine).BeginForeignScan = Some(begin_foreign_scan);
        (*routine).IterateForeignScan = Some(iterate_foreign_scan);
        (*routine).ReScanForeignScan = Some(re_scan_foreign_scan);
        (*routine).EndForeignScan = Some(end_foreign_scan);
        (*routine).PlanForeignModify = Some(plan_foreign_modify);
        (*routine).BeginForeignModify = Some(begin_foreign_modify);
        (*routine).ExecForeignInsert = Some(exec_foreign_insert);
        (*routine).ExecForeignUpdate = Some(exec_foreign_update);
        (*routine).ExecForeignDelete = Some(exec_foreign_delete);
        (*routine).EndForeignModify = Some(end_foreign_modify);
        (*routine).IsForeignRelUpdatable = Some(is_foreign_rel_updatable);
        (*routine).IsForeignScanParallelSafe = Some(is_foreign_scan_parallel_safe);
        (*routine).ImportForeignSchema = Some(import_foreign_schema);
        // GetForeignJoinPaths / GetForeignUpperPaths / direct modify / row
        // marks / analyze / explain stay NULL: unsupported capability is the
        // documented default, not an error.
    }

    pg_sys::Datum::from(routine as usize)
}

/// Postgres requires a `pg_finfo_<fn>` V1 record beside every C-exported
/// function (mirrors `api.rs`'s validator record).
#[no_mangle]
pub extern "C" fn pg_finfo_mcp_fdw_handler() -> &'static pg_sys::Pg_finfo_record {
    const V1: pg_sys::Pg_finfo_record = pg_sys::Pg_finfo_record { api_version: 1 };
    &V1
}

// ── registry helpers ─────────────────────────────────────────────────────────

/// How a foreign table resolves to handler code. Registry tables (PRD-7's
/// ten, by relation name) and PRD-8's generated per-tool tables (by their
/// `tool` table option, §4.5 rule 7).
pub(crate) enum Target {
    Registry(&'static tables::TableEntry),
    PerTool(per_tool::PerToolTarget),
}

/// The relation's own name (unquoted spelling).
unsafe fn relname_for_relid(relid: pg_sys::Oid) -> String {
    cstr_to_string(pg_sys::get_rel_name(relid), "foreign table")
}

/// Resolve a foreign table OID to its handler target. Registry names win;
/// anything else must carry the per-tool `tool` table option — a foreign
/// table with neither raises `0A000` rather than scanning as empty (see
/// module docs).
unsafe fn target_for_relid(relid: pg_sys::Oid) -> Target {
    let name = relname_for_relid(relid);
    if let Some(entry) = tables::find(&name) {
        return Target::Registry(entry);
    }

    let ft = pg_sys::GetForeignTable(relid);
    let options = session::defelem_list((*ft).options);
    let get = |k: &str| options.iter().find(|(n, _)| n == k).map(|(_, v)| v.clone());

    match get("tool") {
        Some(tool) if !tool.is_empty() => {
            // The gate flag is decided at generation and always stamped
            // there; a hand-made table without it stays INSERT-only.
            let invoke_on_select = get("invoke_on_select").is_some_and(|v| v == "true");
            let cache_ttl_ms = get("cache_ttl_ms").and_then(|v| v.parse::<u64>().ok());
            Target::PerTool(per_tool::PerToolTarget {
                tool,
                invoke_on_select,
                cache_ttl_ms,
            })
        }
        _ => McpError::FeatureNotSupported(format!(
            "foreign table \"{name}\" is not managed by mcp_fdw; \
             import it with IMPORT FOREIGN SCHEMA mcp FROM SERVER ... (PRD-7 §4.11) \
             or generate per-tool tables with mcp.generate_functions (PRD-8 §4.6)"
        ))
        .raise(),
    }
}

/// `<schema>.<table>`, quoted — the per-tool error messages' way of naming
/// the INSERT alternative (FR-8.6).
unsafe fn table_qual_for_relid(relid: pg_sys::Oid) -> String {
    let schema_oid = pg_sys::get_rel_namespace(relid);
    let schema = cstr_to_string(
        pg_sys::get_namespace_name(schema_oid),
        "foreign table schema",
    );
    format!(
        "{}.{}",
        crate::codegen::table::quote_ident(&schema),
        crate::codegen::table::quote_ident(&relname_for_relid(relid))
    )
}

unsafe fn cstr_to_string(raw: *const c_char, what: &str) -> String {
    if raw.is_null() {
        McpError::Internal(format!("catalog returned no name for {what}")).raise();
    }
    CStr::from_ptr(raw).to_string_lossy().into_owned()
}

/// The foreign server a foreign table belongs to, by name.
unsafe fn server_name_for_relid(relid: pg_sys::Oid) -> String {
    let server_oid = (*pg_sys::GetForeignTable(relid)).serverid;
    let server = pg_sys::GetForeignServer(server_oid);
    cstr_to_string((*server).servername, "foreign server")
}

/// Resolve the calling role's server + credential for a foreign table (D3, FR-7.18).
unsafe fn resolve_for_relid(
    relid: pg_sys::Oid,
) -> (Target, String, session::Resolved) {
    let target = target_for_relid(relid);
    let server_name = server_name_for_relid(relid);
    let resolved = match session::resolve(&server_name) {
        Ok(r) => r,
        Err(e) => e.raise(),
    };
    (target, server_name, resolved)
}

// ── planner ──────────────────────────────────────────────────────────────────

#[pg_guard]
unsafe extern "C-unwind" fn get_foreign_rel_size(
    _root: *mut pg_sys::PlannerInfo,
    baserel: *mut pg_sys::RelOptInfo,
    foreigntableid: pg_sys::Oid,
) {
    // Constant estimate, deliberately without I/O: the planner must stay
    // synchronous and side-effect free; per-server row counts are what the
    // catalog cache (Track A) is for. `server` is one row by definition
    // (§4.1).
    let target = target_for_relid(foreigntableid);
    (*baserel).rows = match &target {
        Target::Registry(entry) if entry.spec.name == "server" => 1.0,
        // A per-tool table yields one row per result element; a small
        // non-zero estimate keeps nested-loop plans from looking free.
        _ => 1000.0,
    };
}

#[pg_guard]
unsafe extern "C-unwind" fn get_foreign_paths(
    root: *mut pg_sys::PlannerInfo,
    baserel: *mut pg_sys::RelOptInfo,
    _foreigntableid: pg_sys::Oid,
) {
    let rows = (*baserel).rows;
    // Arbitrary-but-plausible costs: full sequential fetch, no startup
    // advantage, no pushdown of sorts/limits. Quals are decided in
    // GetForeignPlan, so the path carries no fdw_restrictinfo.
    let total_cost: pg_sys::Cost = 10.0 + rows * 10.0;
    // The signature drifted across majors: PG18 added `disabled_nodes` (12
    // args), PG17 added `fdw_restrictinfo` (11), PG16 has 10. The path
    // carries no restrictinfo and no disabled nodes on any version, and
    // quals are decided in GetForeignPlan.
    #[cfg(feature = "pg18")]
    let path = pg_sys::create_foreignscan_path(
        root,
        baserel,
        ptr::null_mut(), // no PathTarget: default projection
        rows,
        0,   // disabled_nodes
        0.0, // startup_cost
        total_cost,
        ptr::null_mut(), // pathkeys: no sort pushdown
        (*baserel).lateral_relids,
        ptr::null_mut(), // fdw_outerpath
        ptr::null_mut(), // fdw_restrictinfo
        ptr::null_mut(), // fdw_private
    );
    #[cfg(feature = "pg17")]
    let path = pg_sys::create_foreignscan_path(
        root,
        baserel,
        ptr::null_mut(), // no PathTarget: default projection
        rows,
        0.0, // startup_cost
        total_cost,
        ptr::null_mut(), // pathkeys: no sort pushdown
        (*baserel).lateral_relids,
        ptr::null_mut(), // fdw_outerpath
        ptr::null_mut(), // fdw_restrictinfo
        ptr::null_mut(), // fdw_private
    );
    #[cfg(feature = "pg16")]
    let path = pg_sys::create_foreignscan_path(
        root,
        baserel,
        ptr::null_mut(), // no PathTarget: default projection
        rows,
        0.0, // startup_cost
        total_cost,
        ptr::null_mut(), // pathkeys: no sort pushdown
        (*baserel).lateral_relids,
        ptr::null_mut(), // fdw_outerpath
        ptr::null_mut(), // fdw_private
    );
    pg_sys::add_path(baserel, path as *mut pg_sys::Path);
}

#[pg_guard]
unsafe extern "C-unwind" fn get_foreign_plan(
    _root: *mut pg_sys::PlannerInfo,
    baserel: *mut pg_sys::RelOptInfo,
    foreigntableid: pg_sys::Oid,
    _best_path: *mut pg_sys::ForeignPath,
    tlist: *mut pg_sys::List,
    scan_clauses: *mut pg_sys::List,
    outer_plan: *mut pg_sys::Plan,
) -> *mut pg_sys::ForeignScan {
    let target = target_for_relid(foreigntableid);
    let relname = relname_for_relid(foreigntableid);
    let rt_index = (*baserel).relid as c_int;

    let mut pushed: Vec<Qual> = Vec::new();
    let mut params: Vec<ParamQual> = Vec::new();
    // Param nodes whose values resolve at executor start (`fdw_exprs`), in
    // `params[i].index` order.
    let mut param_nodes: Vec<*mut pg_sys::Node> = Vec::new();
    let mut local: *mut pg_sys::List = ptr::null_mut();

    let n_clauses = if scan_clauses.is_null() {
        0
    } else {
        (*scan_clauses).length as usize
    };
    for i in 0..n_clauses {
        let node = (*(*scan_clauses).elements.add(i)).ptr_value as *mut pg_sys::Node;
        if node.is_null() {
            continue;
        }

        // `scan_clauses` are RestrictInfo nodes; the expression is inside.
        let (clause, pseudoconstant) = if (*node).type_ == pg_sys::NodeTag::T_RestrictInfo {
            let ri = node as *mut pg_sys::RestrictInfo;
            ((*ri).clause as *mut pg_sys::Node, (*ri).pseudoconstant)
        } else {
            (node, false)
        };

        // Pseudoconstants never make sense remotely; keep them local.
        if pseudoconstant {
            local = pg_sys::lappend(local, clause as *mut c_void);
            continue;
        }

        match extract_qual(clause, rt_index, foreigntableid, &target) {
            Some(Pushed::Value(qual)) => pushed.push(qual),
            Some(Pushed::Param(mut pq, param_node)) => {
                pq.index = param_nodes.len();
                param_nodes.push(param_node);
                params.push(pq);
            }
            // Anything we cannot prove is left for Postgres to re-check:
            // never marked as pushed down (§4.8).
            None => local = pg_sys::lappend(local, clause as *mut c_void),
        }
    }

    let mut fdw_exprs: *mut pg_sys::List = ptr::null_mut();
    for param_node in &param_nodes {
        fdw_exprs = pg_sys::lappend(fdw_exprs, (*param_node) as *mut c_void);
    }

    // `fdw_private`: one makeString JSON blob — copyObject-safe by
    // construction, and the only thing BeginForeignScan needs.
    let private = FdwPrivate {
        table: relname,
        quals: pushed,
        params,
    };
    let json = serde_json::to_string(&private)
        .unwrap_or_else(|_| McpError::Internal("could not encode fdw_private".to_string()).raise());
    let c_json = CString::new(json)
        .unwrap_or_else(|_| McpError::Internal("fdw_private contained NUL".to_string()).raise());
    // `makeString` stores the pointer verbatim (no copy), so the string must
    // be pstrdup'd into PostgreSQL memory before the CString drops.
    let private_list = pg_sys::lappend(
        ptr::null_mut(),
        pg_sys::makeString(pg_sys::pstrdup(c_json.as_ptr())) as *mut c_void,
    );

    pg_sys::make_foreignscan(
        tlist,
        local,
        (*baserel).relid,
        fdw_exprs, // Param nodes resolved at executor start (see Pushed::Param)
        private_list,
        ptr::null_mut(), // fdw_scan_tlist: always full-width rows
        ptr::null_mut(), // fdw_recheck_quals: none (no EPQ support)
        outer_plan,
    )
}

/// One successfully recognized pushable clause: a fully-known [`Qual`], or
/// an equality whose value is a plan parameter (resolved at executor start
/// via `fdw_exprs` — see [`ParamQual`]).
enum Pushed {
    Value(Qual),
    Param(ParamQual, *mut pg_sys::Node),
}

/// Try to read one planner clause as a pushable restriction.
///
/// Supported shapes (§4.8): `column = const` and the ScalarArrayOp forms
/// `column = ANY(ARRAY[...])` / `column IN (...)` — both lower to the same
/// node — **on columns the table's handler declares pushdown support for**;
/// plus the parameter-bound equalities generic plans carry (`column = $n`,
/// and the generated functions' `($n IS NULL OR column = $n)` optional
/// shape — SQL-function bodies on pg16/17 always plan that way).
/// Everything else (other operators, NULL constants, expressions, join-side
/// vars) yields `None` and stays local.
unsafe fn extract_qual(
    clause: *mut pg_sys::Node,
    rt_index: c_int,
    relid: pg_sys::Oid,
    target: &Target,
) -> Option<Pushed> {
    // The planner rewrites boolean equality into boolean shapes before we
    // ever see it: `flag = true` becomes the bare Var `flag`, `flag = false`
    // becomes `NOT flag`, and users may write `flag IS TRUE` / `IS FALSE`.
    // Extract those directly, or a boolean input could never be supplied as
    // an argument through a SELECT.
    match (*clause).type_ {
        pg_sys::NodeTag::T_Var => {
            let var = clause as *mut pg_sys::Var;
            return qual_from_var(var, Json::Bool(true), rt_index, relid, target)
                .map(Pushed::Value);
        }
        pg_sys::NodeTag::T_BoolExpr => {
            let bool_expr = clause as *mut pg_sys::BoolExpr;
            if (*bool_expr).boolop == pg_sys::BoolExprType::NOT_EXPR
                && !(*bool_expr).args.is_null()
                && (*(*bool_expr).args).length == 1
            {
                let arg = strip_coercion(
                    (*(*(*bool_expr).args).elements.add(0)).ptr_value as *mut pg_sys::Node,
                );
                if (*arg).type_ == pg_sys::NodeTag::T_Var {
                    let var = arg as *mut pg_sys::Var;
                    return qual_from_var(var, Json::Bool(false), rt_index, relid, target)
                        .map(Pushed::Value);
                }
            }
            // Not a NOT-over-var: the optional-argument OR shape.
            return extract_optional_param_qual(clause, rt_index, relid, target);
        }
        pg_sys::NodeTag::T_BooleanTest => {
            let test = clause as *mut pg_sys::BooleanTest;
            let arg = strip_coercion((*test).arg as *mut pg_sys::Node);
            if (*arg).type_ != pg_sys::NodeTag::T_Var {
                return None;
            }
            let truth = match (*test).booltesttype {
                pg_sys::BoolTestType::IS_TRUE => Json::Bool(true),
                pg_sys::BoolTestType::IS_FALSE => Json::Bool(false),
                _ => return None,
            };
            let var = arg as *mut pg_sys::Var;
            return qual_from_var(var, truth, rt_index, relid, target).map(Pushed::Value);
        }
        _ => {}
    }

    let (opno, args, use_or) = match (*clause).type_ {
        pg_sys::NodeTag::T_OpExpr => {
            let op = clause as *mut pg_sys::OpExpr;
            ((*op).opno, (*op).args, false)
        }
        pg_sys::NodeTag::T_ScalarArrayOpExpr => {
            let saop = clause as *mut pg_sys::ScalarArrayOpExpr;
            ((*saop).opno, (*saop).args, (*saop).useOr)
        }
        _ => return None,
    };

    // Only equality (the `=` operator function for the column's type). Any
    // other operator is unsupported by construction.
    if !is_equality_opcode(pg_sys::get_opcode(opno)) {
        return None;
    }

    let n_args = if args.is_null() {
        0
    } else {
        (*args).length as usize
    };
    if n_args != 2 {
        return None;
    }
    let left = strip_coercion((*(*args).elements.add(0)).ptr_value as *mut pg_sys::Node);
    let right = strip_coercion((*(*args).elements.add(1)).ptr_value as *mut pg_sys::Node);

    // Orient (var, const-or-param); a qual between two vars, two consts, or
    // two params is not ours.
    let (var, value_node) = match ((*left).type_, (*right).type_) {
        (pg_sys::NodeTag::T_Var, pg_sys::NodeTag::T_Const)
        | (pg_sys::NodeTag::T_Var, pg_sys::NodeTag::T_Param) => (left, right),
        (pg_sys::NodeTag::T_Const, pg_sys::NodeTag::T_Var)
        | (pg_sys::NodeTag::T_Param, pg_sys::NodeTag::T_Var) => (right, left),
        _ => return None,
    };

    let var = var as *mut pg_sys::Var;

    let column = var_column(var, rt_index, relid, target)?;

    match (*value_node).type_ {
        pg_sys::NodeTag::T_Const => {
            let value = const_to_json(value_node as *mut pg_sys::Const)?;
            Some(Pushed::Value(match use_or {
                false => Qual::equal(column, value),
                true => Qual::any_equal(column, value.as_array()?.clone()),
            }))
        }
        // A parameter in a scalar-equality position: ScalarArrayOp (`= ANY`)
        // with a parameter stays local — the array value cannot be expressed
        // as one JSON scalar.
        pg_sys::NodeTag::T_Param if !use_or => {
            let param = value_node as *mut pg_sys::Param;
            if (*param).paramkind != pg_sys::ParamKind::PARAM_EXTERN {
                return None;
            }
            Some(Pushed::Param(
                ParamQual {
                    field: column,
                    index: 0, // assigned by the caller
                    omit_null: false,
                    param_type: (*param).paramtype.to_u32(),
                },
                value_node,
            ))
        }
        _ => None,
    }
}

/// Recognize `($n IS NULL OR column = $n)` — the generated functions'
/// optional-argument arm — as one parameter-bound equality.
unsafe fn extract_optional_param_qual(
    clause: *mut pg_sys::Node,
    rt_index: c_int,
    relid: pg_sys::Oid,
    target: &Target,
) -> Option<Pushed> {
    let bool_expr = clause as *mut pg_sys::BoolExpr;
    if (*bool_expr).boolop != pg_sys::BoolExprType::OR_EXPR
        || (*bool_expr).args.is_null()
        || (*(*bool_expr).args).length != 2
    {
        return None;
    }
    let arg0 = strip_coercion((*(*(*bool_expr).args).elements.add(0)).ptr_value as *mut pg_sys::Node);
    let arg1 = strip_coercion((*(*(*bool_expr).args).elements.add(1)).ptr_value as *mut pg_sys::Node);

    // Which arm is the NULL test, which the equality?
    let (null_arm, eq_arm) = match ((*arg0).type_, (*arg1).type_) {
        (pg_sys::NodeTag::T_NullTest, pg_sys::NodeTag::T_OpExpr) => (arg0, arg1),
        (pg_sys::NodeTag::T_OpExpr, pg_sys::NodeTag::T_NullTest) => (arg1, arg0),
        _ => return None,
    };

    let null_test = null_arm as *mut pg_sys::NullTest;
    if (*null_test).nulltesttype != pg_sys::NullTestType::IS_NULL {
        return None;
    }
    let null_param = strip_coercion((*null_test).arg as *mut pg_sys::Node);
    if (*null_param).type_ != pg_sys::NodeTag::T_Param {
        return None;
    }

    // The equality arm must bind the SAME parameter to a column.
    let op = eq_arm as *mut pg_sys::OpExpr;
    if !is_equality_opcode(pg_sys::get_opcode((*op).opno))
        || (*op).args.is_null()
        || (*(*op).args).length != 2
    {
        return None;
    }
    let left = strip_coercion((*(*(*op).args).elements.add(0)).ptr_value as *mut pg_sys::Node);
    let right = strip_coercion((*(*(*op).args).elements.add(1)).ptr_value as *mut pg_sys::Node);
    let (var, param) = match ((*left).type_, (*right).type_) {
        (pg_sys::NodeTag::T_Var, pg_sys::NodeTag::T_Param) => (left, right),
        (pg_sys::NodeTag::T_Param, pg_sys::NodeTag::T_Var) => (right, left),
        _ => return None,
    };
    let eq_param = param as *mut pg_sys::Param;
    let null_param_typed = null_param as *mut pg_sys::Param;
    if (*eq_param).paramid != (*null_param_typed).paramid {
        return None;
    }

    let column = var_column(var as *mut pg_sys::Var, rt_index, relid, target)?;
    if (*eq_param).paramkind != pg_sys::ParamKind::PARAM_EXTERN {
        return None;
    }
    Some(Pushed::Param(
        ParamQual {
            field: column,
            index: 0, // assigned by the caller
            omit_null: true,
            param_type: (*eq_param).paramtype.to_u32(),
        },
        param,
    ))
}

/// The shared column-eligibility gate for one Var: this scan's own real
/// attribute, no outer references, and — for registry tables — a column the
/// registry knows and the handler actually applies (default: no pushdown at
/// all, see `tables/mod.rs`). Per-tool tables allow every column: the
/// runtime handler (`tables/per_tool.rs`) decides which quals become
/// `arguments` and which it post-filters, so nothing is marked pushed that
/// is not genuinely applied.
unsafe fn var_column(
    var: *mut pg_sys::Var,
    rt_index: c_int,
    relid: pg_sys::Oid,
    target: &Target,
) -> Option<String> {
    // Only this scan's own columns, real attributes, no outer references.
    if (*var).varlevelsup != 0 || (*var).varattno <= 0 || (*var).varno as c_int != rt_index {
        return None;
    }

    let column = cstr_to_string(pg_sys::get_attname(relid, (*var).varattno, false), "column");

    match target {
        Target::Registry(entry) => {
            if entry.spec.attno(&column).is_none() {
                return None;
            }
            if !entry.handler.pushdown_columns().contains(&column.as_str()) {
                return None;
            }
        }
        Target::PerTool(_) => {}
    }
    Some(column)
}

/// A boolean-shape clause (`flag`, `NOT flag`, `flag IS TRUE/FALSE`) as an
/// equality qual on the boolean column.
unsafe fn qual_from_var(
    var: *mut pg_sys::Var,
    value: Json,
    rt_index: c_int,
    relid: pg_sys::Oid,
    target: &Target,
) -> Option<Qual> {
    let column = var_column(var, rt_index, relid, target)?;
    Some(Qual::equal(column, value))
}

/// The `=` operator functions this extension recognizes. Kept explicit and
/// small; a new column type means adding its equality function here *and* a
/// [`Cell`] conversion.
fn is_equality_opcode(opcode: pg_sys::Oid) -> bool {
    const EQUALITY_OPCODES: &[pg_sys::Oid] = &[
        pg_sys::Oid::from_u32(pg_sys::F_TEXTEQ),
        pg_sys::Oid::from_u32(pg_sys::F_INT4EQ),
        pg_sys::Oid::from_u32(pg_sys::F_INT8EQ),
        pg_sys::Oid::from_u32(pg_sys::F_BOOLEQ),
        pg_sys::Oid::from_u32(pg_sys::F_BYTEAEQ),
        pg_sys::Oid::from_u32(pg_sys::F_JSONB_EQ),
        pg_sys::Oid::from_u32(pg_sys::F_UUID_EQ),
        // PRD-8 §4.1 types on per-tool tables.
        pg_sys::Oid::from_u32(pg_sys::F_FLOAT8EQ),
        pg_sys::Oid::from_u32(pg_sys::F_DATE_EQ),
        pg_sys::Oid::from_u32(pg_sys::F_TIMESTAMPTZ_EQ),
    ];
    EQUALITY_OPCODES.contains(&opcode)
}

/// Unwrap planner coercion nodes (`RelabelType`, e.g. varchar → text).
unsafe fn strip_coercion(mut node: *mut pg_sys::Node) -> *mut pg_sys::Node {
    while (*node).type_ == pg_sys::NodeTag::T_RelabelType {
        node = (*(node as *mut pg_sys::RelabelType)).arg as *mut pg_sys::Node;
    }
    node
}

/// A `Const` node's value as JSON, by its type. `None` for NULLs and for any
/// type we do not carry in [`Cell`] — those quals stay local.
unsafe fn const_to_json(const_: *mut pg_sys::Const) -> Option<Json> {
    if (*const_).constisnull {
        return None;
    }
    datum_to_json((*const_).consttype, (*const_).constvalue)
}

/// A datum's value as JSON, by its type OID. `None` for any type we do not
/// carry in [`Cell`]/a qual — those quals stay local. Shared by the Const
/// path (plan time) and the Param path (executor start, [`resolve_param_quals`]).
unsafe fn datum_to_json(type_oid: pg_sys::Oid, datum: pg_sys::Datum) -> Option<Json> {
    match type_oid {
        t if t == pg_sys::TEXTOID || t == pg_sys::VARCHAROID || t == pg_sys::BPCHAROID => {
            let raw = pg_sys::text_to_cstring(datum.cast_mut_ptr::<pg_sys::text>());
            Some(Json::String(
                CStr::from_ptr(raw).to_string_lossy().into_owned(),
            ))
        }
        t if t == pg_sys::JSONBOID => {
            let raw = cstring_from_func(pg_sys::jsonb_out, datum);
            serde_json::from_str(&raw).ok()
        }
        t if t == pg_sys::BOOLOID => bool::from_datum(datum, false).map(Json::Bool),
        t if t == pg_sys::INT4OID => i32::from_datum(datum, false).map(|v| Json::from(v)),
        t if t == pg_sys::INT8OID => i64::from_datum(datum, false).map(|v| Json::from(v)),
        // PRD-8 §4.1: per-tool input columns can be typed `double precision`,
        // `uuid`, `date` and `timestamptz`; their constants become JSON so the
        // qual can be pushed into `arguments` and echoed back.
        t if t == pg_sys::FLOAT8OID => f64::from_datum(datum, false).and_then(|v| {
            serde_json::Number::from_f64(v).map(serde_json::Number::into)
        }),
        t if t == pg_sys::UUIDOID => {
            Some(Json::String(cstring_from_func(pg_sys::uuid_out, datum)))
        }
        t if t == pg_sys::DATEOID => Some(Json::String(cstring_from_func(pg_sys::date_out, datum))),
        t if t == pg_sys::TIMESTAMPTZOID => Some(Json::String(pg_timestamptz_to_json(
            &cstring_from_func(pg_sys::timestamptz_out, datum),
        ))),
        _ => None,
    }
}

/// Render PostgreSQL's `timestamptz_out` text ("2026-09-05 10:00:00+00",
/// ISO DateStyle) as an RFC 3339 string ("2026-09-05T10:00:00Z" /
/// "…+05:30"), the shape JSON Schema `date-time` consumers expect on the
/// wire. Anything unusual (BC dates, non-ISO DateStyle output) is passed
/// through unchanged — the value stays a valid string argument either way.
fn pg_timestamptz_to_json(raw: &str) -> String {
    let b = raw.as_bytes();
    let is_iso = b.len() >= 19
        && b[4] == b'-'
        && b[7] == b'-'
        && b[10] == b' '
        && b[13] == b':'
        && b[16] == b':';
    if !is_iso {
        return raw.to_string();
    }

    // Time part starts at 11; "HH:MM:SS" is exactly 8 chars, so any '+'/'-'
    // at or after offset 8 of the time part begins the zone offset (a '.'
    // fractional part, which cannot contain a sign, would sit before it).
    let time = &raw[11..];
    let offset_at = time[8..]
        .char_indices()
        .find(|(_, c)| *c == '+' || *c == '-')
        .map(|(i, _)| 8 + i);
    let (time_core, offset) = match offset_at {
        Some(i) => (&time[..i], &time[i..]),
        None => (time, ""),
    };

    let normalized_offset = match offset {
        "" => String::new(), // no explicit offset: pass through as printed
        "+00" => "Z".to_string(),
        o if o.len() == 3 => format!("{o}:00"), // "+HH"/"-HH" → "+HH:00"
        o => o.to_string(),                     // already "+HH:MM"
    };

    format!("{}T{}{}", &raw[..10], time_core, normalized_offset)
}

/// Decode `byteaout`'s hex form (`\x4142...`) back into bytes.
fn hex_decode_bytea_out(raw: &str) -> Vec<u8> {
    let hex = raw.strip_prefix("\\x").unwrap_or(raw);
    (0..hex.len() / 2)
        .filter_map(|i| u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).ok())
        .collect()
}

/// Call a one-argument `cstring`-output function (e.g. `jsonb_out`, `byteaout`)
/// through pgrx's direct-call helper and read the result as a Rust string.
unsafe fn cstring_from_func(
    func: unsafe fn(pg_sys::FunctionCallInfo) -> pg_sys::Datum,
    arg: pg_sys::Datum,
) -> String {
    let out = pgrx::direct_function_call_as_datum(func, &[Some(arg)]).unwrap_or_else(|| {
        McpError::Internal("type output function returned NULL".to_string()).raise()
    });
    CStr::from_ptr(out.cast_mut_ptr::<c_char>())
        .to_string_lossy()
        .into_owned()
}

/// Call a one-argument input function (e.g. `jsonb_in`, `byteain`) over a
/// cstring datum.
unsafe fn call_in_func(
    func: unsafe fn(pg_sys::FunctionCallInfo) -> pg_sys::Datum,
    arg: pg_sys::Datum,
) -> pg_sys::Datum {
    pgrx::direct_function_call_as_datum(func, &[Some(arg)]).unwrap_or_else(|| {
        McpError::Internal("type input function rejected the value".to_string()).raise()
    })
}

// ── scan executor ────────────────────────────────────────────────────────────

/// `node->fdw_state` payload for scans.
struct ScanHolder {
    cursor: Box<dyn tables::ScanCursor>,
}

/// The foreign table's own OPTIONS, as `import.rs`/`ALTER FOREIGN TABLE`
/// stamped them (PRD-7.E: `upstream`, `cache_ttl_ms` — consumed by the
/// catalog handlers through [`tables::TableContext`]).
///
/// SAFETY: caller guarantees `relid` names an existing foreign table (the
/// planner resolved it); the struct lives in the current memory context.
unsafe fn table_options_for_relid(relid: pg_sys::Oid) -> Vec<(String, String)> {
    // SAFETY: per the caller contract.
    unsafe { crate::session::defelem_list((*pg_sys::GetForeignTable(relid)).options) }
}

#[pg_guard]
unsafe extern "C-unwind" fn begin_foreign_scan(node: *mut pg_sys::ForeignScanState, eflags: c_int) {
    if eflags & pg_sys::EXEC_FLAG_EXPLAIN_ONLY as c_int != 0 {
        return;
    }

    let plan = (*node).ss.ps.plan as *mut pg_sys::ForeignScan;
    let rel = (*node).ss.ss_currentRelation;
    let relid = (*rel).rd_id;
    let relname = relname_for_relid(relid);
    let (target, server_name, resolved) = resolve_for_relid(relid);

    let (mut quals, param_quals) = quals_from_private((*plan).fdw_private, &relname);
    // Parameter-bound equalities (generic plans: SQL-function bodies on
    // pg16/17, any plan after plancache switches to generic) resolve here,
    // where the executor's parameter list is populated on every major.
    quals.extend(resolve_param_quals(plan, node, &param_quals));

    let cursor = match target {
        Target::Registry(entry) => {
            let ctx = ScanContext {
                base: TableContext {
                    spec: entry.spec,
                    server_name,
                    resolved,
                    table_options: table_options_for_relid(relid),
                },
                quals,
            };
            match entry.handler.begin_scan(ctx) {
                Ok(c) => c,
                Err(e) => e.raise(),
            }
        }
        Target::PerTool(pt) => {
            let ctx = per_tool::PerToolContext {
                target: pt,
                table_qual: table_qual_for_relid(relid),
                server_name,
                resolved,
                quals,
            };
            match per_tool::begin_scan(ctx) {
                Ok(c) => c,
                Err(e) => e.raise(),
            }
        }
    };

    (*node).fdw_state = Box::into_raw(Box::new(ScanHolder { cursor })) as *mut c_void;
}

#[pg_guard]
unsafe extern "C-unwind" fn iterate_foreign_scan(
    node: *mut pg_sys::ForeignScanState,
) -> *mut pg_sys::TupleTableSlot {
    let holder = (*node).fdw_state as *mut ScanHolder;
    let slot = (*node).ss.ss_ScanTupleSlot;
    pg_sys::ExecClearTuple(slot);
    if holder.is_null() {
        return slot;
    }

    let row = match (*holder).cursor.iter_scan() {
        Ok(r) => r,
        Err(e) => e.raise(),
    };

    if let Some(row) = row {
        fill_slot(slot, &row);
        pg_sys::ExecStoreVirtualTuple(slot);
    }
    slot
}

#[pg_guard]
unsafe extern "C-unwind" fn re_scan_foreign_scan(node: *mut pg_sys::ForeignScanState) {
    let holder = (*node).fdw_state as *mut ScanHolder;
    if holder.is_null() {
        return;
    }
    if let Err(e) = (*holder).cursor.re_scan() {
        e.raise();
    }
}

#[pg_guard]
unsafe extern "C-unwind" fn end_foreign_scan(node: *mut pg_sys::ForeignScanState) {
    let holder = (*node).fdw_state as *mut ScanHolder;
    if !holder.is_null() {
        // `end_scan` is Drop: cursors release MCP resources on every exit
        // path, including longjmps out of an error (PG runs End nodes on
        // error unwinds for initialized scan states).
        drop(Box::from_raw(holder));
        (*node).fdw_state = ptr::null_mut();
    }
}

/// Fill the scan slot from a registry row. Rows are full `spec` width; the
/// slot normally agrees (it was initialized from the foreign table's
/// descriptor), and a narrower hand-created table simply gets its leading
/// columns filled.
unsafe fn fill_slot(slot: *mut pg_sys::TupleTableSlot, row: &Row) {
    let natts = (*(*slot).tts_tupleDescriptor).natts as usize;
    let values = (*slot).tts_values;
    let nulls = (*slot).tts_isnull;
    for i in 0..natts {
        match row.get(i).and_then(|c| c.as_ref()) {
            None => {
                *nulls.add(i) = true;
                *values.add(i) = pg_sys::Datum::from(0usize);
            }
            Some(cell) => {
                *nulls.add(i) = false;
                *values.add(i) = cell_to_datum(cell);
            }
        }
    }
}

unsafe fn cell_to_datum(cell: &Cell) -> pg_sys::Datum {
    match cell {
        Cell::Text(s) => {
            // A NUL inside a value cannot survive a cstring conversion; strip
            // rather than fail (the wire format forbids it anyway).
            let sanitized = s.replace('\0', "");
            let c = CString::new(sanitized).unwrap_or_else(|_| CString::new("").unwrap());
            pg_sys::Datum::from(pg_sys::cstring_to_text(c.as_ptr()) as usize)
        }
        Cell::Json(v) => {
            let c = CString::new(v.to_string()).unwrap_or_else(|_| CString::new("null").unwrap());
            call_in_func(pg_sys::jsonb_in, pg_sys::Datum::from(c.as_ptr() as usize))
        }
        Cell::Bool(b) => pg_sys::Datum::from(*b),
        Cell::Int4(i) => pg_sys::Datum::from(*i),
        Cell::Int8(i) => pg_sys::Datum::from(*i),
        Cell::Bytea(bytes) => {
            // Hex wire form, matching `byteaout`'s render (kept symmetrical so
            // a round trip through text never corrupts).
            let mut hex = String::with_capacity(2 + bytes.len() * 2);
            hex.push_str("\\x");
            for b in bytes {
                hex.push_str(&format!("{b:02x}"));
            }
            let c = CString::new(hex).unwrap_or_else(|_| CString::new("\\x").unwrap());
            call_in_func(pg_sys::byteain, pg_sys::Datum::from(c.as_ptr() as usize))
        }
        Cell::Uuid(bytes) => {
            let p = pg_sys::palloc(16) as *mut u8;
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), p, 16);
            pg_sys::Datum::from(p as usize)
        }
        Cell::TimestampTz(micros) => pg_sys::Datum::from(*micros),
        Cell::Float8(f) => f
            .into_datum()
            .unwrap_or_else(|| pg_sys::Datum::from(0usize)),
        Cell::Date(d) => {
            let c = CString::new(d.as_str())
                .unwrap_or_else(|_| CString::new("1970-01-01").unwrap());
            call_in_func(pg_sys::date_in, pg_sys::Datum::from(c.as_ptr() as usize))
        }
    }
}

/// Deserialize the pushed quals out of the plan's `fdw_private` (one
/// `makeString` JSON blob; see `get_foreign_plan`). A private list that does
/// not decode to this table's name is plan corruption: `XX000`.
unsafe fn quals_from_private(
    list: *mut pg_sys::List,
    expected_table: &str,
) -> (Vec<Qual>, Vec<ParamQual>) {
    if list.is_null() {
        return (Vec::new(), Vec::new());
    }
    let n = (*list).length as usize;
    for i in 0..n {
        let node = (*(*list).elements.add(i)).ptr_value as *mut pg_sys::Node;
        if node.is_null() || (*node).type_ != pg_sys::NodeTag::T_String {
            continue;
        }
        let s = CStr::from_ptr((*(node as *mut pg_sys::String)).sval)
            .to_string_lossy()
            .into_owned();
        let decoded: FdwPrivate = match serde_json::from_str(&s) {
            Ok(v) => v,
            Err(_) => continue,
        };
        if decoded.table != expected_table {
            McpError::Internal(format!(
                "fdw_private names table \"{}\" but the plan scans \"{}\"",
                decoded.table, expected_table
            ))
            .raise();
        }
        return (decoded.quals, decoded.params);
    }
    (Vec::new(), Vec::new())
}

/// Resolve [`ParamQual`]s against the executor's parameter list (the
/// postgres_fdw pattern): evaluate each `fdw_exprs` Param node in the scan
/// state's expression context — `ecxt_param_list_info` is populated by
/// `ExecAssignExprContext` on every supported major. A NULL resolution binds
/// nothing: a required argument then raises its missing-argument error, and
/// an `omit_null` optional arm simply drops out (pg18's folded custom plans
/// behave identically).
unsafe fn resolve_param_quals(
    plan: *mut pg_sys::ForeignScan,
    node: *mut pg_sys::ForeignScanState,
    params: &[ParamQual],
) -> Vec<Qual> {
    let mut out = Vec::with_capacity(params.len());
    if params.is_empty() {
        return out;
    }
    let planstate = &mut (*node).ss.ps;
    let econtext = (*planstate).ps_ExprContext;
    for pq in params {
        let expr_node = list_node_at((*plan).fdw_exprs, pq.index);
        if expr_node.is_null() {
            McpError::Internal(format!(
                "fdw_exprs entry {} for parameter qual on \"{}\" is missing",
                pq.index, pq.field
            ))
            .raise();
        }
        // SAFETY: the Param node belongs to this plan; the state palloc's
        // into the executor's context and is freed with the estate.
        let expr_state = unsafe { pg_sys::ExecInitExpr(expr_node as *mut pg_sys::Expr, planstate) };
        let mut isnull = false;
        // SAFETY: state/context pair produced above; the signature is the
        // backend's ExecEvalExpr on every supported major.
        let datum = unsafe { pg_sys::ExecEvalExpr(expr_state, econtext, &mut isnull) };
        if isnull {
            continue;
        }
        let Some(value) = (unsafe { datum_to_json(pg_sys::Oid::from_u32(pq.param_type), datum) })
        else {
            continue;
        };
        out.push(Qual::equal(pq.field.clone(), value));
    }
    out
}

/// The `index`-th node of a `List *`, or NULL when out of bounds.
unsafe fn list_node_at(list: *mut pg_sys::List, index: usize) -> *mut pg_sys::Node {
    if list.is_null() || index >= (*list).length as usize {
        return ptr::null_mut();
    }
    (*(*list).elements.add(index)).ptr_value as *mut pg_sys::Node
}

// ── modify executor ──────────────────────────────────────────────────────────

/// `ResultRelInfo->ri_FdwState` payload for modify.
enum ModifyHolder {
    Registry {
        spec: &'static TableSpec,
        server_name: String,
        session: Box<dyn tables::ModifySession>,
    },
    PerTool {
        server_name: String,
        session: Box<dyn per_tool::PerToolModify>,
    },
}

#[pg_guard]
unsafe extern "C-unwind" fn plan_foreign_modify(
    root: *mut pg_sys::PlannerInfo,
    _plan: *mut pg_sys::ModifyTable,
    result_relation: pg_sys::Index,
    _subplan_index: c_int,
) -> *mut pg_sys::List {
    // Only identity: which table this statement targets. Resolution repeats at
    // begin/exec time (D3: nothing captured at plan time is trusted).
    let rte = *(*root).simple_rte_array.add(result_relation as usize);
    let relid = (*rte).relid;
    let name = CString::new(relname_for_relid(relid)).unwrap();
    // pstrdup: makeString does not copy (see get_foreign_plan).
    pg_sys::lappend(
        ptr::null_mut(),
        pg_sys::makeString(pg_sys::pstrdup(name.as_ptr())) as *mut c_void,
    )
}

#[pg_guard]
unsafe extern "C-unwind" fn begin_foreign_modify(
    _mtstate: *mut pg_sys::ModifyTableState,
    rinfo: *mut pg_sys::ResultRelInfo,
    _fdw_private: *mut pg_sys::List,
    _subplan_index: c_int,
    eflags: c_int,
) {
    if eflags & pg_sys::EXEC_FLAG_EXPLAIN_ONLY as c_int != 0 {
        return;
    }

    // FR-7.12: only INSERT reaches a table handler. UPDATE/DELETE are refused
    // here — before any row is scanned — with the PRD's SQLSTATE.
    if (*_mtstate).operation != pg_sys::CmdType::CMD_INSERT {
        let relid = (*(*rinfo).ri_RelationDesc).rd_id;
        McpError::FeatureNotSupported(format!(
            "{} on foreign table \"{}\" is not supported; MCP tables accept INSERT only \
             (PRD-7 §4.7 / PRD-8 §4.2)",
            match (*_mtstate).operation {
                pg_sys::CmdType::CMD_UPDATE => "UPDATE",
                pg_sys::CmdType::CMD_DELETE => "DELETE",
                _ => "this operation",
            },
            cstr_to_string(pg_sys::get_rel_name(relid), "foreign table")
        ))
        .raise();
    }

    let relid = (*(*rinfo).ri_RelationDesc).rd_id;
    let (target, server_name, resolved) = resolve_for_relid(relid);

    let holder = match target {

        Target::Registry(entry) => {
            let ctx = ModifyContext {
                spec: entry.spec,
                server_name: server_name.clone(),
                resolved,
                // tool_calls reads no table options today (the call log is
                // engine-local); carried for context parity with scans.
                table_options: table_options_for_relid(relid),
            };
            let session = match entry.handler.begin_modify(ctx) {
                Ok(s) => s,
                Err(e) => e.raise(),
            };
            ModifyHolder::Registry {
                spec: entry.spec,
                server_name,
                session,
            }
        }
        Target::PerTool(pt) => {
            let ctx = per_tool::PerToolContext {
                target: pt,
                table_qual: table_qual_for_relid(relid),
                server_name: server_name.clone(),
                resolved,
                quals: Vec::new(),
            };
            let session = match per_tool::begin_modify(ctx) {
                Ok(s) => s,
                Err(e) => e.raise(),
            };
            ModifyHolder::PerTool {
                server_name,
                session,
            }
        }
    };

    (*rinfo).ri_FdwState = Box::into_raw(Box::new(holder)) as *mut c_void;
}

#[pg_guard]
unsafe extern "C-unwind" fn exec_foreign_insert(
    _estate: *mut pg_sys::EState,
    rinfo: *mut pg_sys::ResultRelInfo,
    slot: *mut pg_sys::TupleTableSlot,
    _plan_slot: *mut pg_sys::TupleTableSlot,
) -> *mut pg_sys::TupleTableSlot {
    let holder = (*rinfo).ri_FdwState as *mut ModifyHolder;
    if holder.is_null() {
        McpError::Internal("foreign insert ran before begin_foreign_modify".to_string()).raise();
    }
    let relid = (*(*rinfo).ri_RelationDesc).rd_id;

    // Registry tables read the slot by their static spec; per-tool tables
    // read it by the tuple descriptor (their columns are dynamic) and hand
    // plain `(column, JSON)` pairs to the handler, which decides which
    // columns were inputs.
    let row = match &mut (*holder) {
        ModifyHolder::Registry {
            spec,
            server_name,
            session,
        } => {
            let cells = read_slot(slot, *spec);
            let input = InsertRow::new(*spec, cells);
            match session.insert(&input) {
                Ok(r) => r,
                Err(e) => e.raise_ctx(server_name, "tools/call"),
            }
        }
        ModifyHolder::PerTool {
            server_name,
            session,
        } => {
            let supplied = read_slot_json(slot, relid);
            match session.insert(supplied) {
                Ok(r) => r,
                Err(e) => e.raise_ctx(server_name, "tools/call"),
            }
        }
    };

    // Replace the slot's contents with the full-width result row: this is the
    // tuple `RETURNING` sees (FR-7.9).
    let tupdesc = (*slot).tts_tupleDescriptor;
    let mut values: Vec<pg_sys::Datum> = Vec::with_capacity(row.len());
    let mut nulls: Vec<bool> = Vec::with_capacity(row.len());
    for i in 0..(*(*slot).tts_tupleDescriptor).natts as usize {
        match row.get(i).and_then(|c| c.as_ref()) {
            None => {
                nulls.push(true);
                values.push(pg_sys::Datum::from(0usize));
            }
            Some(cell) => {
                nulls.push(false);
                values.push(cell_to_datum(cell));
            }
        }
    }
    // pg16's binding takes `*mut Datum`/`*mut bool`; pg17/18 take `*const`.
    // The `*mut → *const` cast below is accepted by all three, and
    // heap_form_tuple does not mutate its inputs.
    let tuple = pg_sys::heap_form_tuple(
        tupdesc,
        values.as_ptr() as *mut pg_sys::Datum,
        nulls.as_ptr() as *mut bool,
    );
    pg_sys::ExecStoreHeapTuple(tuple, slot, true)
}

#[pg_guard]
unsafe extern "C-unwind" fn exec_foreign_update(
    _estate: *mut pg_sys::EState,
    rinfo: *mut pg_sys::ResultRelInfo,
    _slot: *mut pg_sys::TupleTableSlot,
    _plan_slot: *mut pg_sys::TupleTableSlot,
) -> *mut pg_sys::TupleTableSlot {
    let relid = (*(*rinfo).ri_RelationDesc).rd_id;
    McpError::FeatureNotSupported(format!(
        "UPDATE on foreign table \"{}\" is not supported; the call log is append-only (PRD-7 §4.7)",
        cstr_to_string(pg_sys::get_rel_name(relid), "foreign table")
    ))
    .raise()
}

#[pg_guard]
unsafe extern "C-unwind" fn exec_foreign_delete(
    _estate: *mut pg_sys::EState,
    rinfo: *mut pg_sys::ResultRelInfo,
    _slot: *mut pg_sys::TupleTableSlot,
    _plan_slot: *mut pg_sys::TupleTableSlot,
) -> *mut pg_sys::TupleTableSlot {
    let relid = (*(*rinfo).ri_RelationDesc).rd_id;
    McpError::FeatureNotSupported(format!(
        "DELETE on foreign table \"{}\" is not supported; the call log is append-only (PRD-7 §4.7)",
        cstr_to_string(pg_sys::get_rel_name(relid), "foreign table")
    ))
    .raise()
}

#[pg_guard]
unsafe extern "C-unwind" fn end_foreign_modify(
    _estate: *mut pg_sys::EState,
    rinfo: *mut pg_sys::ResultRelInfo,
) {
    let holder = (*rinfo).ri_FdwState as *mut ModifyHolder;
    if !holder.is_null() {
        drop(Box::from_raw(holder));
        (*rinfo).ri_FdwState = ptr::null_mut();
    }
}

#[pg_guard]
unsafe extern "C-unwind" fn is_foreign_rel_updatable(_rel: pg_sys::Relation) -> c_int {
    // Advertise all three operations: PostgreSQL's `CheckValidResultRel` uses
    // this bitmap only as a coarse gate, and it would reject UPDATE/DELETE
    // with the wrong SQLSTATE (55000). FR-7.12's `0A000` is raised by us in
    // `begin_foreign_modify` instead, with the PRD's wording.
    (1 << pg_sys::CmdType::CMD_INSERT)
        | (1 << pg_sys::CmdType::CMD_UPDATE)
        | (1 << pg_sys::CmdType::CMD_DELETE)
}

#[pg_guard]
unsafe extern "C-unwind" fn is_foreign_scan_parallel_safe(
    _root: *mut pg_sys::PlannerInfo,
    _rel: *mut pg_sys::RelOptInfo,
    _rte: *mut pg_sys::RangeTblEntry,
) -> bool {
    // Sessions and the catalog cache are backend-local by design (ADR-004);
    // the mcp.* functions are PARALLEL UNSAFE for the same reason.
    false
}

/// Read a tuple slot's attributes as `InsertRow` cells, by column type.
/// Output-only columns come back `None` when their type has no insert
/// representation here — §4.7 says supplied values for them are ignored
/// anyway, and no registry table accepts them as input.
unsafe fn read_slot(slot: *mut pg_sys::TupleTableSlot, spec: &'static TableSpec) -> Row {
    let mut cells: Row = Vec::with_capacity(spec.arity());
    for (idx, col) in spec.columns.iter().enumerate() {
        let mut isnull = false;
        let datum = pg_sys::slot_getattr(slot, (idx + 1) as c_int, &mut isnull);
        if isnull {
            cells.push(None);
            continue;
        }
        let cell = match col.pg_type {
            tables::ColumnType::Text => {
                let raw = pg_sys::text_to_cstring(datum.cast_mut_ptr::<pg_sys::text>());
                Cell::Text(CStr::from_ptr(raw).to_string_lossy().into_owned())
            }
            tables::ColumnType::Jsonb => {
                let raw = cstring_from_func(pg_sys::jsonb_out, datum);
                match serde_json::from_str(&raw) {
                    Ok(v) => Cell::Json(v),
                    Err(_) => {
                        McpError::Internal(format!("column \"{}\" holds malformed jsonb", col.name))
                            .raise()
                    }
                }
            }
            tables::ColumnType::Boolean => match bool::from_datum(datum, false) {
                Some(b) => Cell::Bool(b),
                None => {
                    McpError::Internal(format!("column \"{}\" held a NULL datum", col.name)).raise()
                }
            },
            tables::ColumnType::Int4 => match i32::from_datum(datum, false) {
                Some(v) => Cell::Int4(v),
                None => {
                    McpError::Internal(format!("column \"{}\" held a NULL datum", col.name)).raise()
                }
            },
            tables::ColumnType::Int8 => match i64::from_datum(datum, false) {
                Some(v) => Cell::Int8(v),
                None => {
                    McpError::Internal(format!("column \"{}\" held a NULL datum", col.name)).raise()
                }
            },
            tables::ColumnType::Uuid => {
                let mut bytes = [0u8; 16];
                std::ptr::copy_nonoverlapping(datum.cast_mut_ptr::<u8>(), bytes.as_mut_ptr(), 16);
                Cell::Uuid(bytes)
            }
            tables::ColumnType::TimestampTz => match i64::from_datum(datum, false) {
                Some(v) => Cell::TimestampTz(v),
                None => {
                    McpError::Internal(format!("column \"{}\" held a NULL datum", col.name)).raise()
                }
            },
            // bytea on the input side: render as hex via byteaout and decode.
            // No registry column accepts bytea input today (PRD-7 §4.7), so
            // this exists to keep read_slot total, not for throughput.
            tables::ColumnType::Bytea => {
                let raw = cstring_from_func(pg_sys::byteaout, datum);
                Cell::Bytea(hex_decode_bytea_out(&raw))
            }
            // PRD-8 §4.1 types: `number` properties accept float8 input on
            // per-tool INSERT, and `format: date` properties accept dates.
            tables::ColumnType::Float8 => match f64::from_datum(datum, false) {
                Some(v) => Cell::Float8(v),
                None => {
                    McpError::Internal(format!("column \"{}\" held a NULL datum", col.name)).raise()
                }
            },
            tables::ColumnType::Date => {
                let raw = cstring_from_func(pg_sys::date_out, datum);
                Cell::Date(raw)
            }
        };
        cells.push(Some(cell));
    }
    cells
}

/// Read a tuple slot as `(column, JSON)` pairs for a per-tool INSERT, keyed
/// by the slot's own tuple descriptor (the columns are dynamic, unlike the
/// registry's static specs). NULL attributes are `None`; the handler ignores
/// columns it does not take as inputs (§4.7's rule).
unsafe fn read_slot_json(
    slot: *mut pg_sys::TupleTableSlot,
    relid: pg_sys::Oid,
) -> Vec<(String, Option<Json>)> {
    let tupdesc = (*slot).tts_tupleDescriptor;
    let natts = (*tupdesc).natts as usize;
    let mut out = Vec::with_capacity(natts);
    for i in 0..natts {
        let attno = (i + 1) as pg_sys::AttrNumber;
        let name = cstr_to_string(pg_sys::get_attname(relid, attno, false), "insert column name");
        let mut isnull = false;
        let datum = pg_sys::slot_getattr(slot, (i + 1) as c_int, &mut isnull);
        if isnull {
            out.push((name, None));
            continue;
        }
        let atttypid = pg_sys::get_atttype(relid, attno);
        let json = match atttypid {
            t if t == pg_sys::TEXTOID || t == pg_sys::VARCHAROID || t == pg_sys::BPCHAROID => {
                let raw = pg_sys::text_to_cstring(datum.cast_mut_ptr::<pg_sys::text>());
                Json::String(CStr::from_ptr(raw).to_string_lossy().into_owned())
            }
            t if t == pg_sys::JSONBOID => {
                let raw = cstring_from_func(pg_sys::jsonb_out, datum);
                serde_json::from_str(&raw)
                    .unwrap_or_else(|_| McpError::Internal(format!("column \"{name}\" holds malformed jsonb")).raise())
            }
            t if t == pg_sys::BOOLOID => Json::Bool(bool::from_datum(datum, false).unwrap_or(false)),
            t if t == pg_sys::INT4OID => {
                Json::from(i32::from_datum(datum, false).unwrap_or(0))
            }
            t if t == pg_sys::INT8OID => Json::from(i64::from_datum(datum, false).unwrap_or(0)),
            t if t == pg_sys::FLOAT8OID => Json::from(f64::from_datum(datum, false).unwrap_or(0.0)),
            t if t == pg_sys::UUIDOID => {
                Json::String(cstring_from_func(pg_sys::uuid_out, datum))
            }
            t if t == pg_sys::DATEOID => Json::String(cstring_from_func(pg_sys::date_out, datum)),
            t if t == pg_sys::TIMESTAMPTZOID => Json::String(pg_timestamptz_to_json(
                &cstring_from_func(pg_sys::timestamptz_out, datum),
            )),
            t if t == pg_sys::BYTEAOID => {
                Json::String(hex_encode_bytea(cstring_from_func(pg_sys::byteaout, datum).as_str()))
            }
            _ => McpError::Internal(format!(
                "column \"{name}\" has a type the per-tool insert path does not carry"
            ))
            .raise(),
        };
        out.push((name, Some(json)));
    }
    out
}

/// Hex text for a bytea wire argument (`\x…` form, matching byteaout).
fn hex_encode_bytea(bytea_out: &str) -> String {
    bytea_out.to_string()
}

// ── IMPORT FOREIGN SCHEMA ────────────────────────────────────────────────────

#[pg_guard]
unsafe extern "C-unwind" fn import_foreign_schema(
    stmt: *mut pg_sys::ImportForeignSchemaStmt,
    server_oid: pg_sys::Oid,
) -> *mut pg_sys::List {
    // §4.11: the remote schema is fixed; anything else is 3F000.
    let remote = cstr_to_string((*stmt).remote_schema, "remote schema");
    if remote != "mcp" {
        McpError::InvalidSchemaName(format!(
            "the mcp_fdw wrapper exports exactly one remote schema: \"mcp\", not \"{remote}\""
        ))
        .raise();
    }
    let local = cstr_to_string((*stmt).local_schema, "local schema");
    let server = pg_sys::GetForeignServer(server_oid);
    let server_name = cstr_to_string((*server).servername, "foreign server");

    let table_names = |list: *mut pg_sys::List| -> Vec<String> {
        let mut names = Vec::new();
        if list.is_null() {
            return names;
        }
        for i in 0..(*list).length as usize {
            let rv = (*(*list).elements.add(i)).ptr_value as *mut pg_sys::RangeVar;
            names.push(cstr_to_string((*rv).relname, "table name"));
        }
        names
    };

    let filter = match (*stmt).list_type {
        pg_sys::ImportForeignSchemaType::FDW_IMPORT_SCHEMA_LIMIT_TO => {
            TableFilter::LimitTo(table_names((*stmt).table_list))
        }
        pg_sys::ImportForeignSchemaType::FDW_IMPORT_SCHEMA_EXCEPT => {
            TableFilter::Except(table_names((*stmt).table_list))
        }
        _ => TableFilter::All,
    };

    let mut out: *mut pg_sys::List = ptr::null_mut();
    for statement in import::statements(&server_name, &local, &filter) {
        let c = CString::new(statement)
            .unwrap_or_else(|_| McpError::Internal("DDL contained NUL".to_string()).raise());
        // PG18's ImportForeignSchema reads each cell as a *raw C string*
        // (`char *cmd = (char *) lfirst(lc)` in foreigncmds.c), not a String
        // node. The string must be pstrdup'd: the CString drops below.
        out = pg_sys::lappend(out, pg_sys::pstrdup(c.as_ptr()) as *mut c_void);
    }
    out
}

#[cfg(any(test, feature = "pg_test"))]
#[pgrx::pg_schema]
mod tests {
    use super::*;

    const FREEZE_SERVER: &str = "CREATE SERVER {name} FOREIGN DATA WRAPPER mcp_fdw
           OPTIONS (url 'http://127.0.0.1:1/mcp', auth 'none', timeout_ms '1000')";

    /// Assert that `stmt` fails with SQLSTATE `want`.
    ///
    /// Errors raised inside FDW executor callbacks longjmp straight to
    /// PostgreSQL's error machinery and are NOT captured by pgrx's
    /// `Spi::run(..).unwrap_err()` on this runner (unlike fmgr-called
    /// functions), so the statement runs inside a plpgsql `EXCEPTION` block
    /// instead: the SQLSTATE is compared in SQL, where nothing can escape.
    fn expect_sqlstate(stmt: &str, want: &str) {
        let sql = format!(
            r#"
            DO $probe$
            DECLARE got text;
            BEGIN
                BEGIN
                    EXECUTE $stmt${stmt}$stmt$;
                    RAISE EXCEPTION 'NO_ERROR_RAISED';
                EXCEPTION WHEN OTHERS THEN got := SQLSTATE;
                END;
                IF got IS DISTINCT FROM '{want}' THEN
                    RAISE EXCEPTION 'expected SQLSTATE {want}, got %', got;
                END IF;
            END
            $probe$;"#
        );
        Spi::run(&sql)
            .unwrap_or_else(|e| panic!("expect_sqlstate harness failed for {want}: {e:?}"));
    }

    fn make_server(name: &str) {
        Spi::run("CREATE SCHEMA IF NOT EXISTS fdw_freeze").unwrap();
        Spi::run(&FREEZE_SERVER.replace("{name}", name)).unwrap();
    }

    /// The foundation acceptance bar: `IMPORT FOREIGN SCHEMA mcp` creates all
    /// ten registry tables, and scans run the full
    /// planner → GetForeignPlan → BeginForeignScan → Iterate → End chain.
    ///
    /// Track A amendment: `tools`/`server` have real handlers now (PRD-7
    /// §6 step 7.3), so a scan against this unroutable freeze server fails at
    /// `begin_scan` with `08006` rather than scanning as empty — that is the
    /// correct behaviour the freeze test anticipated replacing.
    #[pg_test]
    fn import_creates_the_registry_tables_and_tools_scans_run_end_to_end() {
        make_server("freeze_all");
        Spi::run("CREATE SCHEMA freeze_all_s").unwrap();
        Spi::run("IMPORT FOREIGN SCHEMA mcp FROM SERVER freeze_all INTO freeze_all_s").unwrap();

        let n = Spi::get_one::<i64>(
            "SELECT count(*) FROM pg_class c
               JOIN pg_namespace nsp ON nsp.oid = c.relnamespace
              WHERE nsp.nspname = 'freeze_all_s' AND c.relkind = 'f'",
        )
        .unwrap();
        assert_eq!(n, Some(10), "all ten tables imported");

        // The real handler reaches for the server and fails with the §4.9
        // transport SQLSTATE — proving the scan path executes the handler.
        expect_sqlstate("SELECT count(*) FROM freeze_all_s.tools", "08006");
        expect_sqlstate(
            "SELECT count(*) FROM freeze_all_s.tools WHERE name = 'echo'",
            "08006",
        );
        expect_sqlstate("SELECT count(*) FROM freeze_all_s.server", "08006");
    }

    #[pg_test]
    fn import_honors_limit_to_and_unknown_remote_schema_is_3f000() {
        make_server("freeze_lim");
        Spi::run("CREATE SCHEMA freeze_lim_s").unwrap();
        Spi::run(
            "IMPORT FOREIGN SCHEMA mcp LIMIT TO (tools, tool_calls)
               FROM SERVER freeze_lim INTO freeze_lim_s",
        )
        .unwrap();
        let n = Spi::get_one::<i64>(
            "SELECT count(*) FROM pg_class c
               JOIN pg_namespace nsp ON nsp.oid = c.relnamespace
              WHERE nsp.nspname = 'freeze_lim_s' AND c.relkind = 'f'",
        )
        .unwrap();
        assert_eq!(n, Some(2));

        expect_sqlstate(
            "IMPORT FOREIGN SCHEMA bogus FROM SERVER freeze_lim INTO freeze_lim_s",
            "3F000",
        );
    }

    #[pg_test]
    fn a_role_without_a_user_mapping_still_scans_an_auth_none_server() {
        // FR-7.18 raises 28000 only under `auth 'bearer'`; an auth-none
        // loopback server (the tests') resolves without a mapping. The real
        // 28000 path is covered by PRD-6's missing_user_mapping test through
        // the same `session::resolve` this FDW calls. Track A amendment:
        // `resources` has a real handler now, so "scans" means the handler
        // runs and fails on the unroutable freeze URL with `08006`.
        make_server("freeze_nomap");
        Spi::run("CREATE SCHEMA freeze_nomap_s").unwrap();
        Spi::run("IMPORT FOREIGN SCHEMA mcp FROM SERVER freeze_nomap INTO freeze_nomap_s").unwrap();
        expect_sqlstate("SELECT count(*) FROM freeze_nomap_s.resources", "08006");
    }

    #[pg_test]
    fn insert_into_any_table_but_tool_calls_raises_0a000() {
        make_server("freeze_ins");
        Spi::run("CREATE SCHEMA freeze_ins_s").unwrap();
        Spi::run("IMPORT FOREIGN SCHEMA mcp FROM SERVER freeze_ins INTO freeze_ins_s").unwrap();
        // Every table except `tool_calls` keeps the trait-default
        // `begin_modify`, which refuses with 0A000 (PRD-7 §4.7). This probe
        // guards that refusal on a catalog table now that all ten handlers
        // are real and `tool_calls` accepts INSERT.
        expect_sqlstate(
            "INSERT INTO freeze_ins_s.tools (name) VALUES ('echo')",
            "0A000",
        );
    }

    #[pg_test]
    fn update_and_delete_on_tool_calls_raise_0a000() {
        make_server("freeze_upd");
        Spi::run("CREATE SCHEMA freeze_upd_s").unwrap();
        Spi::run("IMPORT FOREIGN SCHEMA mcp FROM SERVER freeze_upd INTO freeze_upd_s").unwrap();

        expect_sqlstate("UPDATE freeze_upd_s.tool_calls SET tool = 'x'", "0A000");
        expect_sqlstate("DELETE FROM freeze_upd_s.tool_calls", "0A000");
    }

    #[pg_test]
    fn a_foreign_table_outside_the_registry_raises_0a000() {
        make_server("freeze_unknown");
        Spi::run("CREATE SCHEMA freeze_unknown_s").unwrap();
        Spi::run(
            "CREATE FOREIGN TABLE freeze_unknown_s.not_a_table (a text) SERVER freeze_unknown",
        )
        .unwrap();
        expect_sqlstate("SELECT * FROM freeze_unknown_s.not_a_table", "0A000");
    }

    #[pg_test]
    fn explain_of_a_scan_does_not_execute_the_handler() {
        // EXPLAIN (no ANALYZE) must not open a cursor (EXEC_FLAG_EXPLAIN_ONLY)
        // and must not leak the URL or any credential into the plan text.
        make_server("freeze_explain");
        Spi::run("CREATE SCHEMA freeze_explain_s").unwrap();
        Spi::run("IMPORT FOREIGN SCHEMA mcp FROM SERVER freeze_explain INTO freeze_explain_s")
            .unwrap();
        let plan = Spi::get_one::<String>(
            "EXPLAIN (VERBOSE) SELECT name FROM freeze_explain_s.tools WHERE name = 'echo'",
        )
        .unwrap()
        .unwrap_or_default();
        assert!(!plan.contains("127.0.0.1"), "no endpoint in plan: {plan}");
    }
}
