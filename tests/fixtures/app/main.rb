require "msgpack"
require "nokogiri"
require "rainbow"

packed = MessagePack.pack({ "fixture" => "app" })
title = Nokogiri::HTML("<title>purified</title>").at("title").text
puts Rainbow("#{MessagePack.unpack(packed)["fixture"]} #{title}").green
