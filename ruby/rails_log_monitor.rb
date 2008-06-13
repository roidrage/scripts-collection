#!/usr/bin/env ruby

# daemon to scrape response times from rails logs
# Thrown together using code from http://onrails.org/articles/2007/08/31/monitoring-rails-performance-with-munin-and-a-mongrel
# and the daemize code from the ferret server in acts_as_ferret (http://projects.jkraemer.net/acts_as_ferret) for easier 
# daemon handling of the rails log monitor itself.
# 
# Ignores monit's http test calls by default
# 
# Throw this in your lib directory. Run with ruby lib/rails_log_monitor.rb production start. PID file for monit monitoring pleasure
# is in log/rails_log_monitor.pid.

unless ["start", "stop"].include?(ARGV[1]) && ARGV[0]
  puts "Usage: #{__FILE__} <environment> (start|stop)"
  exit(0)
end

RAILS_ENV = ARGV[0]

require "#{File.dirname(__FILE__)}/../config/environment"
require 'rubygems'
require 'file/tail'
require 'mongrel'
require 'yaml'

PORT = ENV['PORT'] || "8888"
LOGFILE = ENV['RAILS_LOG'] || "#{RAILS_ROOT}/log/#{RAILS_ENV}.log"

IGNORE_PATTERNS = %r{^http:// /$}.freeze


class Accumulator
  def initialize
    @values = Array.new()
    @max = 0
  end

  def add( n )
    @values << n
    @max = n if n > @max
  end

  def average(read_only=false)
    return_value = if @values.length == 0
      nil
    else
      @values.inject(0) {|sum,value| sum + value } / @values.length
    end
    @values = Array.new() unless read_only
    
    return_value
  end
  
  def max(read_only=false)
    return_value = @max
    @max = 0 unless read_only
    return_value
  end
  
  def count
    @values.length
  end
  alias_method :length, :count
  alias_method :size, :count
end

$response_data = { :total     => Accumulator.new(),
                   :rendering => Accumulator.new(),
                   :db        => Accumulator.new() }

Thread.abort_on_exception = true

class ResponseTimeHandler < Mongrel::HttpHandler
  def initialize(method)
    @method = method
  end

  def process(request, response)
    response.start(200) do |head,out|
      debug = Mongrel::HttpRequest.query_parse(request.params["QUERY_STRING"]).has_key? "debug"
      head["Content-Type"] = "text/plain"
      output = $response_data.map do |k,v|
        value = v.send(@method, debug)
        formatted = value.nil? ? 'U' : sprintf('%.5f', value)
        
        "#{k}.value #{formatted}"
      end.join("\n")
      output << "\n"
      out.write output
    end
  end
end


class RailsLogMonitor
  def initialize
    @cfg = {:pid_file => "#{RAILS_ROOT}/log/rails_log_monitor.pid"}
  end
  
  def platform_daemon (&block)
    safefork do
      write_pid_file
      trap("TERM") { exit(0) }
      sess_id = Process.setsid
      STDIN.reopen("/dev/null")
      STDOUT.reopen("#{RAILS_ROOT}/log/rails_log_monitor.out", "a")
      STDERR.reopen(STDOUT)
      block.call
    end
  end

  ################################################################################
  # stop the daemon, nicely at first, and then forcefully if necessary
  def stop
    pid = read_pid_file
    raise "rails log monitor doesn't appear to be running" unless pid
    $stdout.puts("stopping rails log monitor...")
    Process.kill("TERM", pid)
    30.times { Process.kill(0, pid); sleep(0.5) }
    $stdout.puts("using kill -9 #{pid}")
    Process.kill(9, pid)
  rescue Errno::ESRCH => e
    $stdout.puts("process #{pid} has stopped")
  ensure
    File.unlink(@cfg[:pid_file]) if File.exist?(@cfg[:pid_file])
  end

  ################################################################################
  def safefork (&block)
    @fork_tries ||= 0
    fork(&block)
  rescue Errno::EWOULDBLOCK
    raise if @fork_tries >= 20
    @fork_tries += 1
    sleep 5
    retry
  end

  #################################################################################
  # create the PID file and install an at_exit handler
  def write_pid_file
    open(@cfg[:pid_file], "w") {|f| f << Process.pid << "\n"}
    at_exit { File.unlink(@cfg[:pid_file]) if read_pid_file == Process.pid }
  end

  #################################################################################
  def read_pid_file
    File.read(@cfg[:pid_file]).to_i if File.exist?(@cfg[:pid_file])
  end
  
  def start
    platform_daemon do
      Thread.new do
        File::Tail::Logfile.tail(LOGFILE) do |line|
          puts "tailing!"
          if line =~ /^Completed in /
            puts line
            parts = line.split(/\s+\|\s+/)
            resp = parts.pop
            requested_url = resp[/http:\/\/[^\]]*/]
            next if requested_url =~ IGNORE_PATTERNS

            parts.each do |part|
              part.gsub!(/Completed in/, "total")
              type, time, pct = part.split(/\s+/)
              type = type.gsub(/:/,'').downcase.to_sym

              $response_data[type].add(time.to_f)
            end
          end
        end
      end
      
      h = Mongrel::HttpServer.new("127.0.0.1", PORT)
      h.register("/avg_response_time", ResponseTimeHandler.new(:average))
      h.register("/max_response_time", ResponseTimeHandler.new(:max))
      h.run.join
    end
  end
end

RailsLogMonitor.new.send(ARGV[1])
