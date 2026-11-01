# SPDX-License-Identifier: MIT
#
# Unit tests of the lock run's logic in bin/bundler-purifier: URL rules,
# mirrors, path sources, the definition and content hashes, the Ruby the
# project asks for, and the configuration the lock run uses. They need no
# network. Run them with
#
#   ruby tests/unit/bundler_purifier_test.rb bin/bundler-purifier

require "minitest/autorun"
require "minitest/mock"
require "tmpdir"

SCRIPT = ARGV.shift || File.expand_path("../../bin/bundler-purifier", __dir__)
load SCRIPT

class BundlerPurifierTest < Minitest::Test
  BP = BundlerPurifier

  # Each test runs in a project of its own, as the CLI runs in the project
  # root; Bundler resolves path sources against the root it finds there.
  def setup
    @dir = Dir.mktmpdir("bundler-purifier-test")
    File.write(File.join(@dir, "Gemfile"), "source \"https://rubygems.org\"\n")
    @previous_dir = Dir.pwd
    Dir.chdir(@dir)
    Bundler.reset!
    BP.instance_variable_set(:@root, @dir)
    BP.instance_variable_set(:@bundler_settings, nil)
  end

  def teardown
    Dir.chdir(@previous_dir)
    FileUtils.rm_rf(@dir)
    ENV.delete("BUNDLE_MIRROR__HTTPS://RUBYGEMS__ORG/")
  end

  def write(rel, content)
    path = File.join(@dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def test_https_git_url_rewrites_ssh_sources
    assert_equal "https://github.com/o/r.git", BP.https_git_url("git@github.com:o/r.git")
    assert_equal "https://github.com/o/r.git", BP.https_git_url("ssh://git@github.com/o/r.git")
    assert_equal "https://git.example.com/g/r", BP.https_git_url("ssh://git@git.example.com:2222/g/r")
    assert_equal "https://github.com/o/r", BP.https_git_url("https://github.com/o/r")
    assert_equal "http://host/r", BP.https_git_url("http://host/r")
  end

  def test_remote_url_ends_with_a_slash
    assert_equal "https://rubygems.org/", BP.remote_url("https://rubygems.org")
    assert_equal "https://rubygems.org/", BP.remote_url("https://rubygems.org/")
  end

  def test_gem_url_of_a_single_remote
    assert_equal "https://rubygems.org/gems/rake-13.0.0.gem",
                 BP.gem_url([URI("https://rubygems.org/")], "rake-13.0.0.gem", "sha256-unused")
  end

  def test_gem_url_of_several_remotes_is_the_one_with_the_cached_hash
    body = "the gem file"
    hash = "sha256-#{Digest::SHA256.base64digest(body)}"
    fetcher = Object.new
    fetcher.define_singleton_method(:fetch_path) do |url|
      raise Gem::RemoteFetcher::FetchError.new("not here", url) if url.start_with?("https://a.example/")
      url.start_with?("https://b.example/") ? body : "another file"
    end
    Gem::RemoteFetcher.stub(:fetcher, fetcher) do
      remotes = [URI("https://a.example/"), URI("https://b.example/"), URI("https://c.example/")]
      assert_equal "https://b.example/gems/x-1.gem", BP.gem_url(remotes, "x-1.gem", hash)
    end
  end

  def test_mirrors_come_from_the_bundler_mirror_setting
    assert_equal [], BP.mirrors_for("https://rubygems.org/gems/rake-13.0.0.gem")
    ENV["BUNDLE_MIRROR__HTTPS://RUBYGEMS__ORG/"] = "https://gems.example.com"
    BP.instance_variable_set(:@bundler_settings, nil)
    assert_equal ["https://gems.example.com/gems/rake-13.0.0.gem"],
                 BP.mirrors_for("https://rubygems.org/gems/rake-13.0.0.gem")
  end

  LOCKFILE = <<~LOCK
    GIT
      remote: https://github.com/o/g
      revision: 0123456789abcdef0123456789abcdef01234567
      specs:
        g (1.0)

    PATH
      remote: ../outside
      specs:
        outside (1.0)

    PATH
      remote: gems/inside
      specs:
        inside (1.0)

    GEM
      remote: https://rubygems.org/
      specs:
        rake (13.0.0)

    PLATFORMS
      ruby

    DEPENDENCIES
      g!
      inside!
      outside!
      rake

    RUBY VERSION
      ruby 3.3.6p108

    BUNDLED WITH
      2.6.9
  LOCK

  def test_external_paths_are_the_path_sources_outside_the_project
    parser = Bundler::LockfileParser.new(LOCKFILE)
    assert_equal ["../outside"], BP.external_paths(parser)
  end

  def test_definition_hash_covers_the_definition_files_only
    write("Gemfile.lock", LOCKFILE)
    write("gems/inside/inside.gemspec", "inside")
    FileUtils.mkdir_p(File.join(@dir, "..", "outside"))
    outside = File.expand_path("../outside/outside.gemspec", @dir)
    File.write(outside, "outside")
    before = BP.definition_hash
    # Files outside the definition do not count.
    write("vendor/cached/x.gemspec", "x")
    write(".hidden/y.gemspec", "y")
    write("lib/code.rb", "puts 1")
    assert_equal before, BP.definition_hash
    # A gemspec of the project or of an external path source counts.
    write("gems/inside/inside.gemspec", "inside, changed")
    refute_equal before, BP.definition_hash
    write("gems/inside/inside.gemspec", "inside")
    File.write(outside, "outside, changed")
    refute_equal before, BP.definition_hash
  ensure
    FileUtils.rm_rf(File.expand_path("../outside", @dir))
  end

  def test_definition_hash_frames_each_file_by_name_and_length
    write("Gemfile", "a")
    expected = "sha256-#{Digest::SHA256.base64digest("Gemfile\n1\na\n")}"
    assert_equal expected, BP.definition_hash
  end

  def test_content_hash_ignores_key_order_and_itself
    a = { "version" => 2, "downloads" => [{ "url" => "u", "path" => "p" }] }
    b = { "downloads" => [{ "path" => "p", "url" => "u" }], "version" => 2 }
    assert_equal BP.content_hash(a), BP.content_hash(b)
    assert_equal BP.content_hash(a), BP.content_hash(a.merge("contentHash" => "anything"))
    refute_equal BP.content_hash(a), BP.content_hash(a.merge("version" => 3))
    expected = "sha256-#{Digest::SHA256.base64digest('{"downloads":[{"path":"p","url":"u"}],"version":2}')}"
    assert_equal expected, BP.content_hash(a)
  end

  def test_project_ruby_version_prefers_dot_ruby_version
    assert_equal "3.3.6", BP.project_ruby_version(LOCKFILE)
    write(".ruby-version", "ruby-3.2.4\n")
    assert_equal "3.2.4", BP.project_ruby_version(LOCKFILE)
  end

  def test_project_ruby_version_is_nil_without_either
    assert_nil BP.project_ruby_version("GEM\n  remote: https://rubygems.org/\n")
  end

  def test_lock_run_config_drops_the_settings_that_narrow_the_lock
    write(".bundle/config", <<~YAML)
      ---
      BUNDLE_WITHOUT: "development:test"
      BUNDLE_PATH: "vendor/bundle"
      BUNDLE_DEPLOYMENT: "true"
      BUNDLE_BUILD__SQLITE3: "--with-flags"
    YAML
    out = File.join(@dir, "lock-config")
    BP.write_lock_run_config(out)
    assert_equal({ "BUNDLE_BUILD__SQLITE3" => "--with-flags" }, YAML.safe_load(File.read(File.join(out, "config"))))
  end

  def test_check_platforms_warns_without_a_linux_platform
    _, err = capture_io { BP.check_platforms(Bundler::LockfileParser.new(LOCKFILE.sub("  ruby\n", "  arm64-darwin\n"))) }
    assert_match(/bundle lock --add-platform x86_64-linux aarch64-linux/, err)
    _, err = capture_io { BP.check_platforms(Bundler::LockfileParser.new(LOCKFILE)) }
    assert_empty err
  end
end
