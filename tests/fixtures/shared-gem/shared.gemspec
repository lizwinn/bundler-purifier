Gem::Specification.new do |spec|
  spec.name = "shared"
  spec.version = "1.0.0"
  spec.summary = "A path gem outside the fixture app, which the app reaches with ../shared-gem"
  spec.authors = ["bundler-purifier"]
  spec.license = "MIT"
  spec.files = `git ls-files -z`.split("\x0").select { |f| f.start_with?("lib/") }
end
