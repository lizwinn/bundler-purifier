require "rainbow"
require_relative "greeting/version"

module Greeting
  def self.hello(name)
    Rainbow("hello, #{name}").bright
  end
end
