require 'juggler/state_machine'

class Juggler
  class JobRunner
    include StateMachine
    
    state :new
    state :running, :pre => :fetch_stats, :enter => :run_strategy
    state :succeeded, :enter => :delete
    state :timed_out, :enter => [:fail_strategy, :release]
    state :failed, :enter => :delete
    state :done
    
    attr_reader :job
    
    def initialize(job, params, strategy)
      @job = job
      @params = params
      @strategy = strategy
      Juggler.logger.debug {
        "#{to_s}: New job with body: #{params}"
      }
      @_state = :new
    end
    
    def run
      change_state(:running)
    end
    
    def check_for_timeout
      if state == :running
        if (time_left = @end_time - Time.now) < 1
          Juggler.logger.info("#{to_s}: Timed out (#{time_left}s left)")
          change_state(:timed_out)
        end
      end
    end
    
    def to_s
      "Job #{@job.jobid}"
    end
    
    private
    
    # Retrives job stats from beanstalkd
    def fetch_stats
      dd = EM::DefaultDeferrable.new

      Juggler.logger.debug { "#{to_s}: Fetching stats" }

      stats_def = job.stats
      stats_def.callback do |stats|
        @stats = stats
        @end_time = Time.now + stats["time-left"]
        Juggler.logger.debug { "#{to_s} stats: #{stats.inspect}"}
        dd.succeed
      end
      stats_def.errback {
        Juggler.logger.error { "#{to_s}: Fetching stats failed" }
        dd.fail
      }

      dd
    end

    # Wraps running the actual job.
    # Returns a deferrable that fails if there is an exception calling the 
    # strategy or if the strategy triggers errback
    def run_strategy
      begin
        sd = @strategy.call(@params)
        sd.callback {
          change_state(:succeeded)
        }
        sd.errback { |e|
          # timed_out error is already handled
          change_state(:failed) unless e == :timed_out
        }
        @strategy_deferrable = sd
      rescue => e
        handle_exception(e, "Exception calling strategy")
        change_state(:failed)
      end
    end
    
    def fail_strategy
      @strategy_deferrable.fail(:timed_out)
    end
    
    # TODO: exponential backoff
    def release
      dd = EM::DefaultDeferrable.new
      
      Juggler.logger.debug { "Job #{job.jobid} releasing" }
      
      release_def = job.release(:delay => 1)
      release_def.callback {
        Juggler.logger.info { "Job #{job.jobid} released for retry" }
        change_state(:done)
      }
      release_def.errback {
        Juggler.logger.error do
          "Job #{job.jobid } release failed (could not release)"
        end
        change_state(:done)
      }
    end
    
    def delete
      dd = job.delete
      dd.callback do
        Juggler.logger.debug "Job #{job.jobid} deleted"
        change_state(:done)
      end
      dd.errback do
        Juggler.logger.debug "Job #{job.jobid} delete operation failed"
        change_state(:done)
      end
    end
    
    def handle_exception(e, message)
      Juggler.logger.error "#{message}: #{e.message} (#{e.class})"
      Juggler.logger.debug e.backtrace.join("\n")
    end
  end
end