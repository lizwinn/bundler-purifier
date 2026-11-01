# SPDX-License-Identifier: MIT
#
# A stand-in for a gem host, for tests/interactive.sh: it answers every
# request with 200 and saves the body of `POST /api/v1/gems`, which is how
# `gem push` uploads a gem file.
#
#   ruby fake-gem-server.rb PORT_FILE UPLOAD_FILE

require "socket"

port_file, upload_file = ARGV
server = TCPServer.new("127.0.0.1", 0)
File.write(port_file, server.addr[1].to_s)

loop do
  client = server.accept
  request_line = client.gets.to_s
  headers = {}
  while (line = client.gets) && line != "\r\n"
    name, value = line.split(":", 2)
    headers[name.downcase] = value.to_s.strip
  end
  body = client.read(headers.fetch("content-length", "0").to_i)
  response = ""
  if request_line.start_with?("POST /api/v1/gems ")
    File.binwrite(upload_file, body)
    response = "Successfully registered gem"
  end
  client.write("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: #{response.bytesize}\r\n" \
               "Connection: close\r\n\r\n#{response}")
  client.close
end
