# frozen_string_literal: true
# typed: strict

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "iskra"
require 'socket'

module Iskra
  class Server
    extend T::Sig

    include ::Iskra::Task::Mixin

    sig { returns(Integer) }
    attr_reader :port

    sig { params(port: Integer, handler: T.proc.params(arg0: String).returns(::Iskra::Task[String])).void }
    def initialize(port, &handler)
      @port         = T.let(port, Integer)
      @handler      = T.let(handler, T.proc.params(arg0: String).returns(::Iskra::Task[String]))
      @stop_channel = Iskra::Channel[NilClass].new(max_size: 1)
    end

    sig { returns(::Iskra::Task[T.anything]) }
    def run
      concurrent do
        blocking! { puts "Server starting on port #{port}"}
        main_socket = blocking! { TCPServer.open("localhost", port) }
        loop do
          is_stopped = check_if_stopped.await!
          break if is_stopped

          connection_socket = blocking! { main_socket.accept }
          blocking! { puts "Received a connection" }
          concurrent do
            request = blocking! { connection_socket.gets }
            blocking! { puts "Received request: #{request}" }
            response = @handler.call(request).await!
            blocking! { puts "Responding with: #{response}" }
            blocking! { connection_socket.puts(response) }
            blocking! { connection_socket.close }
            blocking! { puts "Connection closed" }
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

run_blocking do
  concurrent do
    port = 5000
    server = ::Iskra::Server.new(port) do |req|
      concurrent { "Received: #{req}" }
    end
    
    server.run.await!
  end
end