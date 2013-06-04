require "io/console"
require 'pty'

module Necro
  class Commander
    MAX_PROCESS_COUNT = 10

    def initialize
      # mapping between open pipes and worker classes
      @open_pipes = {}

      # mapping between command label and worker classes
      @workers = {}
      
      @thread_group = ThreadGroup.new()
      @worker_mutex = Mutex.new()
      @reactor = Necro::Reactor.new
      Thread.abort_on_exception = true

      Necro::CONFIG.processes.each do |process_info|
        add_command(process_info)
      end
    end

    def start_reactor
      unix_server_thread = Thread.new do
        Necro::Master::Server.new()
      end
      @thread_group.add(unix_server_thread)
      @reactor.start
    end

    def add_command(process_info)
      m, s = PTY.open
      s.raw! # disable newline conversion.

      pid = run_command(process_info, s)

      s.close()

      worker = Necro::CommandWorker.new(process_info.label, m,  pid)

      add_worker(worker)
      wait_on_pid(process_info.label,pid)
    end

    def add_command_by_label(command_label)
      process_info = Necro::CONFIG.processes.detect {|pconfig|
        pconfig.label == command_label
      }
      if process_info
        add_command(process_info)
      end
    end

    def reload_command(command_label)
      remove_command(command_label)
      add_command_by_label(command_label)
    end

    def remove_command(command_label)
      worker = @workers[command_label]
      if worker
        $stdout.puts("Removing #{command_label}".red)
        Process.kill("INT",worker.pid)
      end
    end

    def get_worker_from_fd(fd)
      @open_pipes[fd.fileno]
    end

    def get_worker_from_label(label)
      @workers[label]
    end
    
    private
    # Remove worker from all collections
    def remove_worker(command_label)
      @worker_mutex.synchronize do
        worker = @workers[command_label]
        if worker
          @open_pipes.delete(worker.pipe_end.fileno)
          @reactor.remove_from_monitoring(worker.pipe_end)
          @workers.delete(command_label)
        end
      end
    end

    # add worker to global collections
    def add_worker(worker)
      @worker_mutex.synchronize do
        @open_pipes[worker.pipe_end.fileno] = worker
        @workers[worker.command_label] = worker
        @reactor.add_to_monitor(worker.pipe_end)
      end
    end

    def run_command(process_info, write_pipe)
      if defined?(Bundler)
        Bundler.with_clean_env do
          spawn(process_info.cmd, 
            :chdir => process_info.dir || "/", :out => write_pipe, :err => write_pipe
          )
        end
      else
        spawn(process_info.cmd, 
          :chdir => process_info.dir || "/", :out => write_pipe, :err => write_pipe
        )
      end
    end

    def wait_on_pid(command_label,pid)
      raise Necro::Errors::ToomanyOpenConnections if @thread_group.enclosed?
      thread = Thread.new do
        Process.wait(pid)
        $stdout.puts("\nProcess with command #{command_label} exited with status #{$?.exitstatus}".red)
        remove_worker(command_label)
      end
      @thread_group.add(thread)
    end

  end
end