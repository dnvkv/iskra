Gem::Specification.new do |spec|
  spec.name          = "iskra"
  spec.version       = "0.0.1"
  spec.summary       = "Set of fully typed utility classes and interfaces integrated with Sorbet."
  spec.description   = spec.summary
  spec.authors       = ["Daniil Bober"]
  spec.files         = Dir["CHANGELOG.md", "LICENSE", "README.md", "mayak.gemspec", "lib/**/*"]
  spec.license       = "MIT"
  spec.executables   = []
  spec.require_paths = ["lib"]

  spec.add_dependency "mayak"
  spec.add_dependency "tapioca"
  spec.add_dependency "sorbet-runtime", "~> 0.5.11142"
  spec.add_dependency "sorbet", "~> 0.5.11142"
  spec.add_dependency "concurrent-ruby", "1.1.7"

  spec.add_development_dependency "bundler"
  spec.add_development_dependency "rspec"
  spec.add_development_dependency "benchmark-ips"
  spec.add_development_dependency 'stackprof'
end