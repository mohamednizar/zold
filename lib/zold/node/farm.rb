# Copyright (c) 2018 Yegor Bugayenko
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the 'Software'), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED 'AS IS', WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

require 'time'
require_relative '../log'
require_relative '../score'

# The farm of scores.
# Author:: Yegor Bugayenko (yegor256@gmail.com)
# Copyright:: Copyright (c) 2018 Yegor Bugayenko
# License:: MIT
module Zold
  # Farm
  class Farm
    attr_reader :best
    def initialize(log: Log::Quiet.new)
      @log = log
      @scores = []
      @threads = []
      @best = []
      @best << Score.new(Time.now, 'localhost', 80)
      @semaphore = Mutex.new
    end

    def start(host, port, strength: 8, threads: 8)
      @best = []
      @scores = Queue.new
      @scores << Score.new(Time.now, host, port, strength: strength)
      @threads = (1..threads).map do |t|
        Thread.new do
          Thread.current.name = "farm-#{t}"
          @log.info("Thread #{Thread.current.name} started")
          loop do
            s = @scores.pop
            next unless s.valid?
            @semaphore.synchronize do
              before = @best.map(&:value).max
              @best << s
              after = @best.map(&:value).max
              @best.reject! { |b| b.value < after }
              if before != after
                @log.info("#{Thread.current.name}: best is #{@best[0]}")
              end
            end
            if @scores.length < 4
              @scores << Score.new(Time.now, host, port, strength: strength)
            end
            @scores << s.next
          end
        end
      end
    end

    def stop
      @threads.each do |t|
        t.exit
        @log.info("Thread #{t.name} terminated")
      end
    end
  end
end
