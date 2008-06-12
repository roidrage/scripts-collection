#!/usr/bin/ruby
require 'erb'
if not ARGV[1] and not ARGV[2] and not ARGV[3]
  puts "Usage: #{__FILE__} <root> <num> <port> to generate for number of mongrels\n"
  exit
end

monitrc = <<END
# Mongrel on port <%= port %>
check process mongrel_<%= port %> with pidfile <%= root %>/current/log/mongrel.<%= port %>.pid
  group mongrel
  start program = "/usr/bin/sudo -H -u deploy /usr/bin/mongrel_rails start -d -e production -p <%= port %> -P log/mongrel.<%= port %>.pid -c <%= root %>/current/"
  stop program = "/usr/bin/mongrel_rails stop -P log/mongrel.<%= port %>.pid -c <%= root %>/current/"

  if failed host 127.0.0.1 port <%= port %> protocol http
    with timeout 20 seconds
    for 2 cycles
    then restart

  if totalmem > 300 Mb for 5 cycles then restart
  if cpu > 70% for 3 cycles then restart
  if loadavg(5min) greater than 10 for 8 cycles then restart
  if 3 restarts within 5 cycles then timeout

END

start_port = ARGV[2].to_i
root = ARGV[0]
count = ARGV[1].to_i

erb = ERB.new monitrc
monitrc_out = ""

0.upto(count) do |increment|
  port = start_port + increment
  monitrc_out << erb.result(binding)
end

puts monitrc_out
