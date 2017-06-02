defmodule Mix.Compilers.Elixir do
  @moduledoc false

  @manifest_vsn :v7

  import Record

  defrecord :module, [:module, :kind, :sources, :beam, :binary]
  defrecord :source, [
    source: nil,
    hash: nil,
    compile_references: [],
    runtime_references: [],
    compile_dispatches: [],
    runtime_dispatches: [],
    external: []
  ]

  @doc """
  Compiles stale Elixir files.

  It expects a `manifest` file, the source directories, the destination
  directory, a flag to know if compilation is being forced or not, and a
  list of any additional compiler options.

  The `manifest` is written down with information including dependencies
  between modules, which helps it recompile only the modules that
  have changed at runtime.
  """
  def compile(manifest, srcs, dest, exts, force, opts) do
    # We fetch the time from before we read files so any future
    # change to files are still picked up by the compiler. This
    # timestamp is used when writing BEAM files and the manifest.
    timestamp = :calendar.universal_time()
    all_paths = MapSet.new(Mix.Utils.extract_files(srcs, exts))

    # 512KB is getting up there on hash sizes for source and external files
    # If we have a lot of these, can slow compilation a lot.
    {large_resource_threshold, opts} = Keyword.pop(opts, :large_resource_threshold, 262144)

    {all_modules, all_sources} = parse_manifest(manifest, dest)
    modified = Mix.Utils.last_modified(manifest)
    prev_paths =
      for source(source: source) <- all_sources, into: MapSet.new(), do: source

    removed =
      prev_paths
      |> MapSet.difference(all_paths)
      |> MapSet.to_list

    hashes = hash_sources(all_sources, large_resource_threshold)

    changed =
      if force do
        # A config, path dependency or manifest has
        # changed, let's just compile everything
        MapSet.to_list(all_paths)
      else

        # Otherwise let's start with the new sources
        new_paths =
          all_paths
          |> MapSet.difference(prev_paths)
          |> MapSet.to_list

        # Plus the sources that have changed in disk
        for(source(source: source, external: external, hash: last_hash) <- all_sources,
            hash = get_lazy_hash(hashes, source),
            is_stale?(last_hash, hash) or is_any_stale?(external, hashes),
            into: new_paths,
            do: source)
      end

    {modules, changed} =
      update_stale_entries(
        all_modules,
        all_sources,
        removed ++ changed,
        stale_local_deps(manifest, modified)
      )

    stale   = changed -- removed
    sources = update_stale_sources(all_sources, removed, changed, hashes)

    cond do
      stale != [] ->
        compile_manifest(manifest, exts, modules, sources, hashes, stale, dest, timestamp, opts)
      removed != [] ->
        write_manifest(manifest, modules, sources, dest, timestamp)
      true ->
        :ok
    end

    {stale, removed}
  end

  defp is_any_stale?(prev_hashes, new_hashes) do
    Enum.any?(prev_hashes, fn {path, prev_hash} -> is_stale?(prev_hash, get_lazy_hash(new_hashes, path)) end)
  end

  # last, current
  # identical hashes are never stale
  def is_stale?({hash,_,_},{hash,_,_}) when hash != nil, do: false
  # Large files only have size and last modified.
  # When size is the same and last run > this run, we're not stale
  def is_stale?({_,size,last_lm},{nil,size,lm}) when last_lm >= lm, do: false
  # If we can't hit a resource for some reason, and that reason is the same, it's stale.
  def is_stale?({:error, reason}, {:error, reason}), do: false
  # All other scenarios: we're not stale
  def is_stale?(_,_), do: true

  defp get_lazy_hash({large_resource_threshold, map}, file) do
    case Map.fetch(map, file) do
      {:ok, bin_or_nil} -> bin_or_nil
      :error -> hash(file, large_resource_threshold)
    end
  end

  defp hash(path, large_resource_threshold) do
    now = :calendar.universal_time()
    case File.stat(path) do
      {:ok, %File.Stat{size: size, mtime: mtime}} ->
        cond do
          mtime > now ->
            Mix.shell.error("warning: mtime (modified time) for \"#{path}\" was set to the future, resetting to now")
            File.touch!(path, now)
          true ->
            now
        end
        hash = if size <= large_resource_threshold and large_resource_threshold > 0 do
          File.stream!(path, [:raw, :read_ahead, :binary, :read], 4096)
          |> Enum.reduce(:crypto.hash_init(:sha512), fn input,ctx ->
            :crypto.hash_update(ctx,input)
          end)
          |> :crypto.hash_final()
        end
        {hash, size, mtime}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp hash_sources(sources, large_resource_threshold) do
    source_hashes = Enum.reduce(sources, %{}, fn source(source: source, external: external), map ->
      Enum.reduce(external, map, fn {file, _old_hash}, map ->
        put_new_lazy_hash(map, file, large_resource_threshold)
      end) |> put_new_lazy_hash(source, large_resource_threshold)
    end)
    {large_resource_threshold, source_hashes}
  end
  defp put_new_lazy_hash(map, file, large_resource_threshold) do
    case Map.has_key?(map, file) do
      true -> map
      false -> Map.put_new(map, file, hash(file, large_resource_threshold))
    end
  end

  @doc """
  Removes compiled files for the given `manifest`.
  """
  def clean(manifest, compile_path) do
    Enum.each(read_manifest(manifest, compile_path), fn
      module(beam: beam) ->
        File.rm(beam)
      _ ->
        :ok
    end)
  end

  @doc """
  Returns protocols and implementations for the given `manifest`.
  """
  def protocols_and_impls(manifest, compile_path) do
    for module(beam: beam, module: module, kind: kind) <- read_manifest(manifest, compile_path),
        match?(:protocol, kind) or match?({:impl, _}, kind),
        do: {module, kind, beam}
  end

  @doc """
  Reads the manifest.
  """
  def read_manifest(manifest, compile_path) do
    try do
      manifest |> File.read!() |> :erlang.binary_to_term()
    else
      [@manifest_vsn | data] ->
        expand_beam_paths(data, compile_path)
      _ ->
        []
    rescue
      _ -> []
    end
  end

  defp compile_manifest(manifest, exts, modules, sources, hashes, stale, dest, timestamp, opts) do
    Mix.Utils.compiling_n(length(stale), hd(exts))
    Mix.Project.ensure_structure()
    true = Code.prepend_path(dest)
    set_compiler_opts(opts)
    cwd = File.cwd!

    extra =
      if opts[:verbose] do
        [each_file: &each_file/1]
      else
        []
      end

    # Starts a server responsible for keeping track which files
    # were compiled and the dependencies between them.
    {:ok, pid} = Agent.start_link(fn -> {modules, sources} end)
    long_compilation_threshold = opts[:long_compilation_threshold] || 10

    try do
      _ = Kernel.ParallelCompiler.files stale,
            [each_module: &each_module(pid, cwd, hashes, &1, &2, &3),
             each_long_compilation: &each_long_compilation(&1, long_compilation_threshold),
             long_compilation_threshold: long_compilation_threshold,
             dest: dest] ++ extra
      Agent.cast pid, fn {modules, sources} ->
        write_manifest(manifest, modules, sources, dest, timestamp)
        {modules, sources}
      end
    after
      Agent.stop(pid, :normal, :infinity)
    end

    :ok
  end

  defp set_compiler_opts(opts) do
    opts
    |> Keyword.take(Code.available_compiler_options)
    |> Code.compiler_options()
  end

  defp each_module(pid, cwd, hashes, source, module, binary) do
    {compile_references, runtime_references} = Kernel.LexicalTracker.remote_references(module)

    compile_references =
      compile_references
      |> List.delete(module)
      |> Enum.reject(&match?("elixir_" <> _, Atom.to_string(&1)))

    runtime_references =
      runtime_references
      |> List.delete(module)

    {compile_dispatches, runtime_dispatches} = Kernel.LexicalTracker.remote_dispatches(module)

    compile_dispatches =
      compile_dispatches
      |> Enum.reject(&match?("elixir_" <> _, Atom.to_string(elem(&1, 0))))

    runtime_dispatches =
      runtime_dispatches
      |> Enum.to_list

    kind     = detect_kind(module)
    source   = Path.relative_to(source, cwd)
    external = get_external_resources(module, cwd) |> Enum.map(&{&1, get_lazy_hash(hashes, &1)})

    Agent.cast pid, fn {modules, sources} ->
      source_external = case List.keyfind(sources, source, source(:source)) do
        source(external: old_external) -> external ++ old_external
        nil -> external
      end

      module_sources = case List.keyfind(modules, module, module(:module)) do
        module(sources: old_sources) -> [source | List.delete(old_sources, source)]
        nil -> [source]
      end

      new_module = module(
        module: module,
        kind: kind,
        sources: module_sources,
        beam: nil, # They are calculated when writing the manifest
        binary: binary
      )

      new_source = source(
        source: source,
        hash: get_lazy_hash(hashes, source),
        compile_references: compile_references,
        runtime_references: runtime_references,
        compile_dispatches: compile_dispatches,
        runtime_dispatches: runtime_dispatches,
        external: source_external
      )

      modules = List.keystore(modules, module, module(:module), new_module)
      sources = List.keystore(sources, source, source(:source), new_source)
      {modules, sources}
    end
  end

  defp detect_kind(module) do
    protocol_metadata = Module.get_attribute(module, :protocol_impl)

    cond do
      is_list(protocol_metadata) and protocol_metadata[:protocol] ->
        {:impl, protocol_metadata[:protocol]}
      is_list(Module.get_attribute(module, :protocol)) ->
        :protocol
      true ->
        :module
    end
  end

  defp get_external_resources(module, cwd) do
    for file <- Module.get_attribute(module, :external_resource),
        do: Path.relative_to(file, cwd)
  end

  defp each_file(source) do
    Mix.shell.info "Compiled #{source}"
  end

  defp each_long_compilation(source, threshold) do
    Mix.shell.info "Compiling #{source} (it's taking more than #{threshold}s)"
  end

  ## Resolution

  defp update_stale_sources(sources, removed, changed, hashes) do
    # Remove delete sources
    sources =
      Enum.reduce(removed, sources, &List.keydelete(&2, &1, source(:source)))
    # Store empty sources for the changed ones as the compiler appends data
    sources =
      Enum.reduce(changed, sources, &List.keystore(&2, &1, source(:source), source(source: &1, hash: get_lazy_hash(hashes, &1))))
    sources
  end

  # This function receives the manifest entries and some source
  # files that have changed. It then, recursively, figures out
  # all the files that changed (via the module dependencies) and
  # return the non-changed entries and the removed sources.
  defp update_stale_entries(modules, _sources, [], stale) when stale == %{} do
    {modules, []}
  end

  defp update_stale_entries(modules, sources, changed, stale) do
    changed = Enum.into(changed, %{}, &{&1, true})
    remove_stale_entries(modules, sources, stale, changed)
  end

  defp remove_stale_entries(modules, sources, old_stale, old_changed) do
    {rest, new_stale, new_changed} =
      Enum.reduce modules, {[], old_stale, old_changed}, &remove_stale_entry(&1, &2, sources)

    if map_size(new_stale) > map_size(old_stale) or
       map_size(new_changed) > map_size(old_changed) do
      remove_stale_entries(rest, sources, new_stale, new_changed)
    else
      {rest, Map.keys(new_changed)}
    end
  end

  defp remove_stale_entry(module(module: module, beam: beam, sources: sources) = entry,
                          {rest, stale, changed}, sources_records) do
    {compile_references, runtime_references} =
      Enum.reduce(sources, {[], []}, fn source, {compile_acc, runtime_acc} ->
        source(compile_references: compile_refs, runtime_references: runtime_refs) =
          List.keyfind(sources_records, source, source(:source))
        {compile_refs ++ compile_acc, runtime_refs ++ runtime_acc}
      end)

    cond do
      # If I changed in disk or have a compile time reference to
      # something stale, I need to be recompiled.
      has_any_key?(changed, sources) or has_any_key?(stale, compile_references) ->
        remove_and_purge(beam, module)
        {rest,
         Map.put(stale, module, true),
         Enum.reduce(sources, changed, &Map.put(&2, &1, true))}

      # If I have a runtime references to something stale,
      # I am stale too.
      has_any_key?(stale, runtime_references) ->
        {[entry | rest], Map.put(stale, module, true), changed}

      # Otherwise, we don't store it anywhere
      true ->
        {[entry | rest], stale, changed}
    end
  end

  defp has_any_key?(map, enumerable) do
    Enum.any?(enumerable, &Map.has_key?(map, &1))
  end

  defp stale_local_deps(manifest, modified) do
    base = Path.basename(manifest)
    for %{scm: scm, opts: opts} = dep <- Mix.Dep.cached(),
        not scm.fetchable?,
        Mix.Utils.last_modified(Path.join(opts[:build], base)) > modified,
        path <- Mix.Dep.load_paths(dep),
        beam <- Path.wildcard(Path.join(path, "*.beam")),
        Mix.Utils.last_modified(beam) > modified,
        do: {beam |> Path.basename |> Path.rootname |> String.to_atom, true},
        into: %{}
  end

  defp remove_and_purge(beam, module) do
    _ = File.rm(beam)
    _ = :code.purge(module)
    _ = :code.delete(module)
  end

  ## Manifest handling

  # Similar to read_manifest, but supports data migration.
  defp parse_manifest(manifest, compile_path) do
    try do
      manifest |> File.read!() |> :erlang.binary_to_term()
    rescue
      _ -> {[], []}
    else
      [@manifest_vsn | data] -> do_parse_manifest(data, compile_path)
      _ -> {[], []}
    end
  end

  defp do_parse_manifest(data, compile_path) do
    Enum.reduce(data, {[], []}, fn
      module() = module, {modules, sources} ->
        {[expand_beam_path(module, compile_path) | modules], sources}
      source() = source, {modules, sources} ->
        {modules, [source | sources]}
    end)
  end

  defp expand_beam_path(module(beam: beam) = module, compile_path) do
    module(module, beam: Path.join(compile_path, beam))
  end

  defp expand_beam_paths(modules, ""), do: modules
  defp expand_beam_paths(modules, compile_path) do
    Enum.map(modules, fn
      module() = module ->
        expand_beam_path(module, compile_path)
      other ->
        other
    end)
  end

  defp write_manifest(manifest, [], [], _compile_path, _timestamp) do
    File.rm(manifest)
    :ok
  end

  defp write_manifest(manifest, modules, sources, compile_path, timestamp) do
    File.mkdir_p!(Path.dirname(manifest))

    modules =
      for module(binary: binary, module: module) = entry <- modules do
        beam = Atom.to_string(module) <> ".beam"
        if binary do
          beam_path = Path.join(compile_path, beam)
          File.write!(beam_path, binary)
          File.touch!(beam_path, timestamp)
        end
        module(entry, binary: nil, beam: beam)
      end

    manifest_data =
      [@manifest_vsn | modules ++ sources]
      |> :erlang.term_to_binary([:compressed])

    File.write!(manifest, manifest_data)
    File.touch!(manifest, timestamp)

    # Since Elixir is a dependency itself, we need to touch the lock
    # so the current Elixir version, used to compile the files above,
    # is properly stored.
    Mix.Dep.ElixirSCM.update
  end
end
