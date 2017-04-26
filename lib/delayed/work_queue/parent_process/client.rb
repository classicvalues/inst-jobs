module Delayed
module WorkQueue
class ParentProcess
  class Client
    attr_reader :addrinfo

    include Delayed::Logging

    def initialize(addrinfo, config: Settings.parent_process)
      @addrinfo = addrinfo
      @connect_timeout = config['client_connect_timeout'] || 2
      @receive_timeout = config['client_receive_timeout'] || 10
    end

    def get_and_lock_next_available(worker_name, worker_config)
      Marshal.dump([worker_name, worker_config], socket)

      # We're assuming there won't ever be a partial write here so we only need
      # to wait for anything to be available on the 'wire', this is a valid
      # assumption because we control the server and it's a Unix domain socket,
      # not TCP.
      if socket.wait_readable(@receive_timeout)
        return reset_connection if socket.eof? # Other end closed gracefully, so should we
        Marshal.load(socket).tap do |response|
          unless response.nil? || (response.is_a?(Delayed::Job) && response.locked_by == worker_name)
            raise(ProtocolError, "response is not a locked job: #{response.inspect}")
          end
        end
      else
        reset_connection
      end
    rescue SystemCallError, IOError => ex
      logger.error("Work queue connection lost, reestablishing on next poll. (#{ex})")
      # The work queue process died. Return nil to signal the worker
      # process should sleep as if no job was found, and then retry.
      reset_connection
    end

    private

    def socket
      @socket ||= @addrinfo.connect(timeout: @connect_timeout)
    end

    def reset_connection
      if @socket
        @socket.close
        @socket = nil
      end
    end
  end
end
end
end