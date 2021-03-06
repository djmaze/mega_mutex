require File.dirname(__FILE__) + '/../spec_helper'

module MegaMutex
  describe MegaMutex do
    include MegaMutex

    def logger
      Logging::Logger['Specs']
    end

    abort_on_thread_exceptions

    describe "#with_distributed_mutex" do
      it "returns the value returned by the block" do
        result = with_distributed_mutex("foo-#{rand(1000000)}") { 12345 }
        expect(result).to eq 12345
      end
    end

    describe "two blocks, one fast, one slow" do
      before(:each) do
        @errors = []
        @mutually_exclusive_block = lambda do
          @errors << "Someone else is running this code!" if @running
          @running = true
          sleep 0.5
          @running = nil
        end
      end

      describe "with no lock" do
        it "trying to run the block twice should raise an error" do
          threads << Thread.new(&@mutually_exclusive_block)
          threads << Thread.new(&@mutually_exclusive_block)
          wait_for_threads_to_finish
          expect(@errors).not_to be_empty
        end
      end

      describe "with the same lock key" do
        before(:each) do
          Dalli::Client.new(MegaMutex.configuration.memcache_servers).delete(mutex_id)
        end

        def mutex_id
          'tests-mutex-key'
        end

        [2, 20].each do |n|
          describe "when #{n} blocks try to run at the same instant in the same process" do
            it "should run each in turn" do
              n.times do
                threads << Thread.new{ with_distributed_mutex(mutex_id, &@mutually_exclusive_block) }
              end
              wait_for_threads_to_finish
              expect(@errors).to be_empty
            end
          end
        end

        describe "when the first block raises an exception" do
          before(:each) do
            with_distributed_mutex(mutex_id) do
              raise "Something went wrong in my code"
            end rescue nil
          end

          it "the second block should find that the lock is clear and it can run" do
            @success = nil
            with_distributed_mutex(mutex_id) do
              @success = true
            end
            expect(@success).to be_truthy
          end
        end

        describe "when two blocks try to run at the same instant in different processes" do
          before(:each) do
            @lock_file   = File.expand_path(File.dirname(__FILE__) + '/tmp_lock')
            @errors_file = File.expand_path(File.dirname(__FILE__) + '/tmp_errors')
            @mutually_exclusive_block = lambda {
              File.open(@errors_file, 'w').puts "Someone else is running this code!" if File.exists?(@lock_file)
              FileUtils.touch @lock_file
              sleep 1
              File.delete @lock_file
            }
          end

          after(:each) do
            File.delete @lock_file   if File.exists?(@lock_file)
            File.delete @errors_file if File.exists?(@errors_file)
          end

          it "should run each in turn" do
            pids = []
            pids << fork { with_distributed_mutex(mutex_id, &@mutually_exclusive_block); Kernel.exit! }
            pids << fork { with_distributed_mutex(mutex_id, &@mutually_exclusive_block); Kernel.exit! }
            pids.each{ |p| Process.wait(p) }
            if File.exists?(@errors_file)
              raise "Expected no errors but found #{File.read(@errors_file)}"
            end
          end
        end

      end
    end

    describe "with a timeout" do

      it "should raise an error if the code blocks for longer than the timeout" do
        @exception = nil
        @first_thread_has_started = false
        threads << Thread.new do
          with_distributed_mutex('foo') do
            @first_thread_has_started = true
            sleep 0.2
          end
        end
        threads << Thread.new do
          sleep 0.1 until @first_thread_has_started
          begin
            with_distributed_mutex('foo', :timeout => 0.1 ) do
              raise 'this code should never run'
            end
          rescue Exception => @exception
          end
        end
        wait_for_threads_to_finish
        expect(@exception).to be_an_instance_of(MegaMutex::TimeoutError)
      end
    end

    describe "with an expiry" do

      before(:each) do
        Dalli::Client.new(MegaMutex.configuration.memcache_servers).delete(mutex_id)
      end

      def mutex_id
        'foo'
      end

      it "should be able to lock again after the expiry time" do
        pid = fork do
          with_distributed_mutex(mutex_id, :expires_in => 1) { sleep 10 }
        end

        sleep 0.25

        @mutex_entered = false
        expect do
          with_distributed_mutex(mutex_id, :timeout => 3) { @mutex_entered = true }
        end.to_not raise_exception
        expect(@mutex_entered).to be_truthy

        Process.kill('HUP', pid)
      end
    end
  end
end
