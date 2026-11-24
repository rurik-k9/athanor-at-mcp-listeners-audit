# Compiles lib/at_mcp/{listeners,repos}.ex from one at_mcp commit with the Elixir
# inside the hum.10 release, against that release's own modules. No network.
out = System.fetch_env!("OVERLAY_OUT")
src = System.fetch_env!("OVERLAY_SRC")
File.mkdir_p!(out)
Code.put_compiler_option(:ignore_module_conflict, true)
Code.put_compiler_option(:docs, false)
files = [Path.join(src, "listeners.ex"), Path.join(src, "repos.ex")]
case Kernel.ParallelCompiler.compile_to_path(files, out, return_diagnostics: true) do
  {:ok, mods, %{compile_warnings: w}} ->
    IO.puts("COMPILED\t#{mods |> Enum.map(&inspect/1) |> Enum.sort() |> Enum.join(",")}\twarnings=#{length(w)}")
  {:error, errors, _} ->
    IO.puts("FAILED\t#{inspect(errors, limit: 5)}")
    System.halt(1)
end
