# frozen_string_literal: true

# Copyright (c) 2018-2019 Zerocracy, Inc.
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

require 'rainbow'
require 'slop'
require 'json'
require 'net/http'
require 'concurrent'
require_relative 'thread_badge'
require_relative 'args'
require_relative '../thread_pool'
require_relative '../hands'
require_relative '../age'
require_relative '../size'
require_relative '../log'
require_relative '../id'
require_relative '../http'
require_relative '../json_page'

# PUSH command.
# Author:: Yegor Bugayenko (yegor256@gmail.com)
# Copyright:: Copyright (c) 2018 Yegor Bugayenko
# License:: MIT
module Zold
  # Wallet pushing command
  class Push
    prepend ThreadBadge

    # Raises when there are only edge nodes and not a single master one.
    class EdgesOnly < StandardError; end

    # Raises when there are not enough successful nodes.
    class NoQuorum < StandardError; end

    def initialize(wallets:, remotes:, log: Log::NULL)
      @wallets = wallets
      @remotes = remotes
      @log = log
    end

    def run(args = [])
      opts = Slop.parse(args, help: true, suppress_errors: true) do |o|
        o.banner = "Usage: zold push [ID...] [options]
Available options:"
        o.bool '--ignore-score-weakness',
          'Don\'t complain when their score is too weak',
          default: false
        o.bool '--tolerate-edges',
          'Don\'t fail if only "edge" (not "master" ones) nodes accepted the wallet',
          default: false
        o.integer '--tolerate-quorum',
          'The minimum number of nodes required for a successful fetch (default: 4)',
          default: 4
        o.bool '--quiet-if-missed',
          'Don\'t fail if the wallet wasn\'t delivered to any remotes',
          default: false
        o.array '--ignore-node',
          'Ignore this node and don\'t push to it',
          default: []
        o.integer '--threads',
          'How many threads to use for pushing wallets (default: 1)',
          default: 1
        o.integer '--retry',
          'How many times to retry each node before reporting a failure (default: 2)',
          default: 2
        o.bool '--help', 'Print instructions'
      end
      mine = Args.new(opts, @log).take || return
      list = mine.empty? ? @wallets.all : mine.map { |i| Id.new(i) }
      Hands.exec(opts['threads'], list.uniq) do |id|
        push(id, opts)
      end
    end

    private

    def push(id, opts)
      raise "There are no remote nodes, run 'zold remote reset'" if @remotes.all.empty?
      @wallets.acq(id) do |wallet|
        raise "The wallet #{id} is absent at #{wallet.path}" unless wallet.exists?
      end
      start = Time.now
      total = Concurrent::AtomicFixnum.new
      nodes = Concurrent::AtomicFixnum.new
      done = Concurrent::AtomicFixnum.new
      masters = Concurrent::AtomicFixnum.new
      @remotes.iterate(@log) do |r|
        nodes.increment
        total.increment(push_one(id, r, opts))
        masters.increment if r.master?
        done.increment
      end
      unless opts['quiet-if-missed']
        if done.value.zero?
          raise "No nodes out of #{nodes.value} accepted the wallet #{id}; run 'zold remote update' and try again"
        end
        if masters.value.zero? && !opts['tolerate-edges']
          raise EdgesOnly, "There are only edge nodes, run 'zold remote update' or use --tolerate-edges"
        end
        if nodes.value < opts['tolerate-quorum']
          raise NoQuorum, "There were not enough nodes, the required quorum is #{opts['tolerate-quorum']}; \
run 'zold remote update' or use --tolerate-quorum=1"
        end
      end
      @log.info("Push finished to #{done.value} nodes (#{masters.value} master nodes) \
out of #{nodes.value} in #{Age.new(start)}, total score for #{id} is #{total.value}")
    end

    def push_one(id, r, opts)
      if opts['ignore-node'].include?(r.to_s)
        @log.debug("#{r} ignored because of --ignore-node")
        return 0
      end
      start = Time.now
      read_one(id, r, opts) do |json, score|
        r.assert_valid_score(score)
        r.assert_score_ownership(score)
        r.assert_score_strength(score) unless opts['ignore-score-weakness']
        if @log.info?
          @log.info("#{r} accepted #{@wallets.acq(id, &:mnemo)} in #{Age.new(start, limit: 4)}: \
#{Rainbow(score.value).green} (#{json['version']})")
        end
        score.value
      end
    end

    def read_one(id, r, opts)
      start = Time.now
      uri = "/wallet/#{id}"
      attempt = 0
      begin
        response = Tempfile.open do |f|
          @wallets.acq(id) { |w| FileUtils.copy_file(w.path, f.path) }
          r.http(uri).put(f)
        end
        if response.status == 304
          @log.info("#{r}: same version of #{@wallets.acq(id, &:mnemo)} there, didn't push \
in #{Age.new(start, limit: 0.5)}")
          return 0
        end
        r.assert_code(200, response)
        json = JsonPage.new(response.body, uri).to_hash
        score = Score.parse_json(json['score'])
        yield json, score
      rescue JsonPage::CantParse, Score::CantParse, RemoteNode::CantAssert => e
        attempt += 1
        if attempt < opts['retry']
          @log.error("#{r} failed to push #{id}, trying again (attempt no.#{attempt}): #{e.message}")
          retry
        end
        raise e
      end
    end
  end
end
