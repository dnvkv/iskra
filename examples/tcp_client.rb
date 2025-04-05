# frozen_string_literal: true
# typed: strict

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "iskra"
require 'socket'

module Iskra
  class TCPClient
    extend T::Sig

    include ::Iskra::Task::Mixin

    sig { params(host: String, port: Integer).void }
    def initialize(host , port)
      @host = T.let(host, String)
      @port = T.let(port, Integer)
    end

    sig { params(request: String).returns(::Iskra::Task[String]) }
    def send_request(request)
      concurrent do
        client_socket = blocking! { TCPSocket.new(@host, @port) }
        blocking! { client_socket.puts(request) }
        result = blocking! { client_socket.gets }
        blocking! { client_socket.close }
        result
      end
    end
  end
end

include ::Iskra::Task::Mixin

run_blocking do
  concurrent do
    starting = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    100.times do
      concurrent do
        Iskra::TCPClient.new("localhost", 5000).send_request("Hello world").await!
      end
    end
    ending = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    blocking! { puts(ending - starting) }
  end
end