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

require_relative 'log'

module Zold
  # Class to manage data upgrades (when zold itself upgrades).
  class Upgrades
    def initialize(version, directory, log: Log::Verbose.new)
      @version = version
      @directory = directory
      @log = log
    end

    # @todo #285:30min Write the upgrade manager tests that ensure:
    #  - Nothing breaks without the version file.
    #  - The upgrade scripts run when there is a version file and there are pending upgrade scripts.
    #  - Make sure *only* the correct upgrade scripts run.
    def run
      scripts.each do |script|
        @version.apply(script)
      end
    end

    private

    def scripts
      Dir.glob("#{@directory}/*.rb").sort.map do |path|
        basename = File.basename(path)
        match = basename.match(/^(\d+\.\d+\.\d+)\.rb$/)
        raise 'An upgrade script has to be named <version>.rb.' unless match
        match[1]
      end
    end
  end
end