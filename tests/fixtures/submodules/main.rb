require "sassc"

puts SassC::Engine.new(".purified { width: 1px + 2px; }", style: :compressed).render
