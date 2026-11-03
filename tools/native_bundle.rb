# SPDX-License-Identifier: MIT
# Lend Bundler an input-aware Gemfile while preserving the user's manifest.
require "json"
require "tempfile"
require "fileutils"

module PurifierNativeBundle
  def self.run(arguments, root:, views:, ruby:, bundle:, persist_lock: false, env: {})
    working_directory = ENV.fetch("BUNDLER_PURIFIER_WORKING_DIRECTORY", root)
    return system(env, ruby, bundle, *arguments, chdir: working_directory) if views.empty?

    command = arguments.find { |argument| !argument.start_with?("-") }
    env = env.merge("BUNDLER_PURIFIER_RUNTIME" => %w[exec console].include?(command) ? "1" : "0")
    packages = views.each_with_object({}) do |view, result|
      catalog = JSON.parse(File.read(view.fetch("catalog")))
      entries = catalog.fetch("packages") + catalog.fetch("intrinsics", []).map { |entry| entry.merge("intrinsic" => true) }
      entries.each do |entry|
        name = entry.fetch("name")
        candidate = entry.merge("repository" => "file://#{view.fetch('repository')}/")
        if result.key?(name) && (
          result[name].fetch("version") != candidate.fetch("version") ||
          !!result[name]["intrinsic"] != !!candidate["intrinsic"] ||
          (candidate["intrinsic"] ? result[name]["sdk"] != candidate["sdk"] : result[name]["integrity"] != candidate["integrity"]))
          raise "bundler-purifier: conflicting Nix inputs for #{name}"
        end
        result[name] = candidate
      end
    end
    input_data = Marshal.dump(packages).unpack1("H*")
    if (persistent = ENV["BUNDLER_PURIFIER_PERSISTENT_GEMFILE"])
      native_env = env.merge("BUNDLE_GEMFILE" => persistent,
                             "BUNDLER_PURIFIER_INPUT_DATA" => input_data)
      return system(native_env, ruby, bundle, *arguments, chdir: working_directory)
    end
    manifest = File.join(root, "Gemfile")
    original_lock = manifest + ".lock"
    facade = Tempfile.new([".bundler-purifier-", ".Gemfile"], root)
    facade_lock = facade.path + ".lock"
    facade.write("require #{File.join(__dir__, 'rubygems_inputs.rb').inspect}\n")
    facade.write("eval_gemfile #{manifest.inspect}\n")
    facade.close
    FileUtils.cp(original_lock, facade_lock) if File.file?(original_lock)
    native_env = env.merge("BUNDLE_GEMFILE" => facade.path,
                           "BUNDLER_PURIFIER_INPUT_VIEWS" => JSON.dump(views),
                           "BUNDLER_PURIFIER_ORIGINAL_GEMFILE" => manifest,
                           "BUNDLER_PURIFIER_INPUT_DATA" => input_data)
    unless command.nil? || %w[config lock update add remove install version help].include?(command)
      require "bundler"
      needs_binding = !File.file?(facade_lock) || Bundler::LockfileParser.new(File.read(facade_lock)).specs.any? do |spec|
        next false unless (package = packages[spec.name])
        source = spec.source
        spec.version.to_s != package.fetch("version") ||
          !source.is_a?(Bundler::Source::Rubygems) ||
          (package["intrinsic"] ? !source.remotes.empty? : !source.remotes.any? { |remote| remote.to_s.delete_suffix("/") == package.fetch("repository").delete_suffix("/") })
      end
      if needs_binding
        return false unless system(native_env, ruby, bundle, "lock", "--local", chdir: root, out: STDERR)
      end
    end
    result = system(native_env, ruby, bundle, *arguments, chdir: working_directory)
    FileUtils.cp(facade_lock, original_lock) if result && persist_lock && File.file?(facade_lock)
    result
  ensure
    FileUtils.rm_f(facade_lock) if facade_lock
    facade&.unlink
  end
end
