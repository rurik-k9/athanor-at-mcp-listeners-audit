# Compiles every lib/at_mcp module an at_mcp commit changed since the base release (copied under /src),
# with the Elixir inside the base release, against that release's own modules. No network.
# Pass 1 loads the new modules into memory, retrying until each compiles, so a macro that calls a changed
# module at compile time sees its new version. Pass 2 writes the beams.
out = System.fetch_env!("OVERLAY_OUT")
src = System.fetch_env!("OVERLAY_SRC")
File.mkdir_p!(out)
Code.put_compiler_option(:ignore_module_conflict, true)
Code.put_compiler_option(:docs, false)
files = Path.wildcard(Path.join(src, "**/*.ex")) |> Enum.sort()
pending =
  Enum.reduce(1..length(files), files, fn _, left ->
    Enum.reject(left, fn f ->
      try do
        Code.compile_file(f); true
      rescue
        _ -> false
      end
    end)
  end)
if pending != [], do: IO.puts("FAILED\tpass 1: #{inspect(pending)}") && System.halt(1)
case Kernel.ParallelCompiler.compile_to_path(files, out, return_diagnostics: true) do
  {:ok, mods, %{compile_warnings: w}} ->
    IO.puts("COMPILED\t#{length(files)} files\t#{mods |> Enum.map(&inspect/1) |> Enum.sort() |> Enum.join(",")}\twarnings=#{length(w)}")
  {:error, errors, _} ->
    IO.puts("FAILED\t#{inspect(errors, limit: 5)}")
    System.halt(1)
end
