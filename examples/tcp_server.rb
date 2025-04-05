# frozen_string_literal: true
# typed: strict

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "iskra"
require 'socket'
require 'json'

require 'stackprof'

module Iskra
  class TCPServer
    extend T::Sig

    include ::Iskra::Task::Mixin

    sig { returns(Integer) }
    attr_reader :port

    sig {
      params(
        port:    Integer,
        ttl:     T.nilable(Float),
        handler: T.proc.params(arg0: String).returns(::Iskra::Task[String])
      ).void
    }
    def initialize(port, ttl: nil, &handler)
      @port         = T.let(port, Integer)
      @handler      = T.let(handler, T.proc.params(arg0: String).returns(::Iskra::Task[String]))
      @ttl          = T.let(ttl, T.nilable(Float))
      @stop_channel = Iskra::Channel[NilClass].new(max_size: 1)
    end

    sig { returns(::Iskra::Task[T.anything]) }
    def run
      concurrent do
        blocking! { puts "Server starting on port #{port}"}
        main_socket = blocking!(label: "main-socket-listen") { ::TCPServer.open("localhost", port) }
        if !@ttl.nil?
          concurrent do
            delay(@ttl)
            blocking! { puts "stop" }
            stop
          end
        end
        req_count = 0
        loop do
          is_stopped = check_if_stopped.await!
          break if is_stopped

          connection_socket = blocking! { main_socket.accept }
          req_count += 1
          blocking! { puts "Received a connection" }
          concurrent do
            request = blocking!(label: "connection-socket-read-#{req_count}") { connection_socket.gets }
            blocking! { puts "Received request: `#{request}` for #{req_count}" }
            response = @handler.call(request).await!
            blocking! { puts "Responding with: `#{response}` for #{req_count}" }
            blocking!(label: "connection-socket-write-#{req_count}") { connection_socket.puts(response) }
            blocking!(label: "connection-socket-close-#{req_count}") { connection_socket.close }
            blocking! { puts "Connection closed for #{req_count}" }
          end
        end

        blocking! { main_socket.close }
      end
    end

    sig { returns(::Iskra::Task[T.anything]) }
    def stop
      @stop_channel.post(nil)
    end

    private

    sig { returns(::Iskra::Task[T::Boolean]) }
    def check_if_stopped
      concurrent { @stop_channel.size.await! > 0 }
    end
  end
end


include ::Iskra::Task::Mixin

profile = StackProf.run(mode: :wall, raw: true) do
  run_blocking do
    concurrent do
      port = 5000
      server = ::Iskra::TCPServer.new(port, ttl: 10.0) do |req|
        concurrent(label: "Request handler") { "Received: #{req}" }
      end
      
      server.run.await!
    end
  end
end

File.write('tmp/stackprof.json', JSON.generate(profile))