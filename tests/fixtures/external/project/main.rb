require "rainbow"

puts Rainbow("external purified with rainbow #{Gem.loaded_specs["rainbow"].version}").green
