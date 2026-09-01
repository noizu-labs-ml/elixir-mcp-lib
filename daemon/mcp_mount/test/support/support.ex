defmodule McpMount.Support do
  @moduledoc false

  @doc "Poll `fun` until it returns a truthy value (returned), or flunk after `timeout` ms."
  def wait_until(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    case fun.() do
      nil -> throw_deadline(deadline, fun)
      value -> value
    end
  end

  defp throw_deadline(deadline, fun) do
    if System.monotonic_time(:millisecond) >= deadline do
      flunk_wait()
    else
      Process.sleep(50)
      do_wait(fun, deadline)
    end
  end

  defp flunk_wait,
    do: raise(ExUnit.AssertionError, message: "wait_until: condition not met within timeout")

  @doc """
  Write `content` to `mount/rel` and wait for `check` (a 0-arity fun); if the
  watcher push isn't observed in time, re-touch the file — fsevents delivery
  can wobble right after a watcher starts.
  """
  def write_and_wait_push(mount, rel, content, check, timeout \\ 8_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    path = Path.join(mount, rel)
    do_write(path, content, check, deadline)
  end

  defp do_write(path, content, check, deadline) do
    File.write!(path, content)

    quiet_deadline = (System.monotonic_time(:millisecond) + 2_000) |> Kernel.min(deadline)

    if wait_until_quiet(check, quiet_deadline) do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk_wait()
      else
        do_write(path, content, check, deadline)
      end
    end
  end

  defp wait_until_quiet(check, deadline) do
    if check.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(50)
        wait_until_quiet(check, deadline)
      end
    end
  end
end
