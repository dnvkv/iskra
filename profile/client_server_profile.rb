# frozen_string_literal: true
# typed: ignore

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "iskra"
require 'stackprof'

require_relative "../examples/tcp_client"
require_relative "../examples/tcp_server"

include ::Iskra::DSL::Mixin

server_tp = ::Iskra::ThreadPool.new(min_threads: 4, max_threads: 4)
server_runtime = ::Iskra::Runtime.new(thread_pool: server_tp)

profile = StackProf.run(mode: :wall, raw: true) do
  run_blocking(server_runtime) do
    concurrent do
      port = 5000
      server = ::Iskra::TCPServer.new(port, ttl: 10.0) do |req|
        concurrent(label: "Request handler") { "Received: #{req}" }
      end
      
      server.run.await!
    end
  end
end

cl = Thread.new do
  client_tp      = ::Iskra::ThreadPool.new(min_threads: 4, max_threads: 4)
  client_runtime = ::Iskra::Runtime.new(thread_pool: client_tp)
  run_blocking(client_runtime) do
    concurrent do
      starting = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      10.times do
        concurrent do
          Iskra::TCPClient.new("localhost", 5000).send_request("Hello world").await!
        end
      end
      ending = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      blocking! { puts(ending - starting) }
    end
  end
end