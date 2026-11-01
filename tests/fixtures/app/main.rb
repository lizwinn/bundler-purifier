require "helper"
require "msgpack"
require "nokogiri"
require "rainbow"
require "shared"

packed = MessagePack.pack({ "fixture" => Shared.word })
title = Nokogiri::HTML("<title>#{Helper.word}</title>").at("title").text
puts Rainbow("#{MessagePack.unpack(packed)["fixture"]} #{title}").green
