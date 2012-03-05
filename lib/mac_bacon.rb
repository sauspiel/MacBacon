# Bacon -- small RSpec clone.
#
# "Truth will sooner come out from error than from confusion." ---Francis Bacon

# Copyright (C) 2007, 2008 Christian Neukirchen <purl.org/net/chneukirchen>
#
# Bacon is freely distributable under the terms of an MIT-style license.
# See COPYING or http://www.opensource.org/licenses/mit-license.php.

framework "Cocoa"

# TODO
#require "mac_bacon/helpers"

# We need to use Kernel::print when printing which specification is being run.
# But we want to know this as soon as possible, hence we need to sync.
$stdout.sync = true

module Bacon
  VERSION = "1.3"

  Shared = Hash.new { |_, name|
    raise NameError, "no such context: #{name.inspect}"
  }

  class << self
    attr_accessor :restrict_name, :restrict_context

    attr_accessor :backtraces

    # This can be used by a `client' to receive status updates:
    # * When a spec has finished running.
    # * When a context has ran all of its spec.
    # * When Bacon has finished a spec run.
    attr_accessor :delegate

    attr_accessor :concurrent
    alias_method  :concurrent?, :concurrent

    def clear
      @contexts = @current_context_index = @specifications = @requirements = nil
    end

    def contexts
      @contexts ||= []
    end

    def specifications
      @specifications ||= []
    end

    def requirements
      @requirements ||= []
    end

    # TODO these things should go and replaced by a loop that just loops over the contexts and then specs
    def current_context_index
      @current_context_index ||= 0
    end

    def current_context
      contexts[current_context_index]
    end

    # IMPORTANT!
    #
    # Make sure to never call this method directly from the main GCD queue.
    # Instead do something like:
    #
    #   Bacon.performSelector('run', withObject:nil, afterDelay:0)
    def run
      @timer ||= Time.now
      #handle_context_begin(current_context)
      #current_context.performSelector("run", withObject:nil, afterDelay:0)
      self.performSelector("run_all_specs_concurrent", withObject:nil, afterDelay:0)
      NSApplication.sharedApplication.run
    end

    def run_all_specs_concurrent
      queue = Dispatch::Queue.concurrent
      group = Dispatch::Group.new
      contexts.each do |context|
        context.specifications.each do |spec|
          queue.async(group) do
            begin
              spec.run
            rescue Object => e
              puts "An error occurred on a GCD thread, this should really not happen! The error was: #{e.message}\n\t#{e.backtrace.join("\n\t")}"
            end
          end
        end
      end
      # TODO make this work again
      #Bacon.context_did_finish(self)

      group.notify(queue) do
        if delegate && delegate.respond_to?('baconDidFinish')
          delegate.baconDidFinish
        end
        handle_summary
        exit Counter.not_passed
      end
    end

    def context_did_finish(context)
      handle_context_end(context)
      if (@current_context_index + 1) < contexts.size
        @current_context_index += 1
        run
      else
        # DONE
        if delegate && delegate.respond_to?('baconDidFinish')
          delegate.baconDidFinish
        end
        handle_summary
        exit Specification.specifications.select { |s| !s.passed? }.size
      end
    end
  end

  self.restrict_name = //
  self.restrict_context = //
  self.backtraces = true
  # TODO for now we always run concurrent, because I ripped out the code needed for non-concurrent running
  self.concurrent = true

  module Counter
    class << self
      def specifications_ran
        Bacon.specifications.select(&:finished?).size
      end

      def requirements_ran
        Bacon.requirements.size
      end

      def not_passed
        Bacon.specifications.select { |s| !s.passed? }.size
      end

      def failures
        Bacon.specifications.select(&:failure?).size
      end

      def errors
        Bacon.specifications.select(&:error?).size
      end
    end
  end

  # TODO for now we'll just use dots, which works best in a concurrent env
  module SpecDoxOutput
    def handle_context_begin(context)
      # Nested contexts do _not_ have an extra line between them and their parent.
      #puts if context.context_depth == 1

      #spaces = "  " * (context.context_depth - 1)
      #puts spaces + context.name
    end

    def handle_context_end(context)
    end

    def handle_specification_begin(specification)
      #spaces = "  " * (specification.context.class.context_depth - 1)
      ##print "#{spaces}  - #{specification.description}"
      #puts "#{spaces}  - #{specification.description}"
    end

    def handle_specification_end(error)
      #puts error.empty? ? "" : " [#{error}]"
      print '.'
    end

    def summary
      "%d specifications (%d requirements), %d failures, %d errors" %
        [Counter.specifications_ran, Counter.requirements_ran, Counter.failures, Counter.errors]
    end

    def handle_summary
      if Bacon.backtraces
        puts
        Bacon.specifications.each do |spec|
          puts spec.error_log unless spec.passed?
          puts
        end
      end
      puts "Took: %.6f seconds." % (Time.now - @timer).to_f
      @timer = nil
      puts
      puts summary
    end
  end

  extend SpecDoxOutput          # default

  class Error < RuntimeError
    attr_accessor :count_as

    def initialize(count_as, message)
      @count_as = count_as
      super message
    end

    def count_as_failure?
      @count_as == :failure
    end

    def count_as_error?
      @count_as == :error
    end
  end

  class Specification
    attr_reader :description, :context

    def initialize(context, description, block, before_filters, after_filters)
      @context, @description, @block = context, description, block
      @before_filters, @after_filters = before_filters.dup, after_filters.dup

      @postponed_blocks_count = 0
      @ran_spec_block = false
      @ran_after_filters = false
      @finished = false

      Bacon.specifications << self
    end

    def run
      Dispatch::Queue.main.sync do
        Bacon.handle_specification_begin(self)
        if (d = Bacon.delegate) && d.respond_to?('baconSpecificationWillStart:')
          d.baconSpecificationWillStart(self)
        end
      end

      @before_filters.each { |f| @context.instance_eval(&f) }
      @number_of_requirements_before = Bacon.requirements.size
      @context.instance_eval(&@block)

      if passed? && Bacon.requirements.size == @number_of_requirements_before
        # the specification did not contain any requirements, so it flunked
        raise Error.new(:missing, "empty specification: #{@context.class.name} #{@description}")
      end

    rescue Object => e
      @exception = e
    ensure
      begin
        @after_filters.each { |f| @context.instance_eval(&f) }
      rescue Object => e
        @exception = e
      ensure
        @finished = true
        Dispatch::Queue.main.sync do
          Bacon.handle_specification_end(error_message || '')
          # TODO is it still needed to send it to Context?
          @context.class.specification_did_finish(self)
        end
      end
    end

    def finished?
      @finished
    end

    def passed?
      @exception.nil?
    end

    def bacon_error?
      @exception.kind_of?(Error)
    end

    def failure?
      @exception.count_as_failure? if bacon_error?
    end

    def error?
      !@exception.nil? && !failure?
    end

    def error_message
      if bacon_error?
        @exception.count_as.to_s.upcase
      elsif @exception
        "ERROR: #{@exception.class}"
      end
    end

    def error_log
      if @exception
        log = ''
        log << "#{@exception.class}: #{@exception.message}\n"
        lines = $DEBUG ? @exception.backtrace : @exception.backtrace.find_all { |line| line !~ /bin\/macbacon|\/mac_bacon\.rb:\d+/ }
        lines.each_with_index { |line, i|
          log << "\t#{line}#{i==0 ? ": #{@context.class.name} - #{@description}" : ""}\n"
        }
        log
      end
    end
  end

  class Context
    def raise?(*args, &block); block.raise?(*args); end
    def throw?(*args, &block); block.throw?(*args); end
    def change?(*args, &block); block.change?(*args); end

    def should(*args, &block)
      if self.class.context_depth == 0
        it('should '+args.first,&block)
      else
        super(*args,&block)
      end
    end

    class << self
      attr_reader :name, :block, :context_depth, :specifications

      def init_context(name, context_depth, before = nil, after = nil, &block)
        context = Class.new(self) do
          @name = name
          @before, @after = (before ? before.dup : []), (after ? after.dup : [])
          @block = block
          @specifications = []
          @context_depth = context_depth
          @current_specification_index = 0
        end
        Bacon.contexts << context
        context.class_eval(&block)
        context
      end

      # TODO remove this stuff, we simply dispatch them from a loop
      def current_specification
        specifications[@current_specification_index]
      end

      def specification_did_finish(spec)
        if (d = Bacon.delegate) && d.respond_to?('baconSpecificationDidFinish:')
          d.baconSpecificationDidFinish(spec)
        end
        unless Bacon.concurrent?
          # TODO update to no longer use the runloop to schedule specs
          if (@current_specification_index + 1) < specifications.size
            @current_specification_index += 1
            run
          else
            Bacon.context_did_finish(self)
          end
        end
      end

      def before(&block); @before << block; end
      def after(&block);  @after << block; end

      def behaves_like(*names)
        names.each { |name| class_eval(&Shared[name]) }
      end

      def it(description, &block)
        return  unless description =~ Bacon.restrict_name
        block ||= lambda { should.flunk "not implemented" }
        @specifications << Specification.new(new, description, block, @before, @after)
      end

      def describe(*args, &block)
        args.unshift(name)
        init_context(args.join(' '), @context_depth + 1, @before, @after, &block)
      end
    end
  end
end


class Object
  def true?; false; end
  def false?; false; end
end

class TrueClass
  def true?; true; end
end

class FalseClass
  def false?; true; end
end

class Proc
  def raise?(*exceptions)
    call
  rescue *(exceptions.empty? ? RuntimeError : exceptions) => e
    e
  else
    false
  end

  def throw?(sym)
    catch(sym) {
      call
      return false
    }
    return true
  end

  def change?
    pre_result = yield
    called = call
    post_result = yield
    pre_result != post_result
  end
end

class Numeric
  def close?(to, delta)
    (to.to_f - self).abs <= delta.to_f  rescue false
  end
end


class Object
  def should(*args, &block)    Should.new(self).be(*args, &block)                     end
end

module Kernel
  private
  def describe(*args, &block) Bacon::Context.init_context(args.join(' '), 1, &block)  end
  def shared(name, &block)    Bacon::Shared[name] = block                             end
end

class Should
  # Kills ==, ===, =~, eql?, equal?, frozen?, instance_of?, is_a?,
  # kind_of?, nil?, respond_to?, tainted?
  instance_methods.each { |name| undef_method name  if name =~ /\?|^\W+$/ }

  def initialize(object)
    @object = object
    @negated = false
    Bacon.requirements << self
  end

  def not(*args, &block)
    @negated = !@negated

    if args.empty?
      self
    else
      be(*args, &block)
    end
  end

  def be(*args, &block)
    if args.empty?
      self
    else
      block = args.shift  unless block_given?
      satisfy(*args, &block)
    end
  end

  alias a  be
  alias an be

  def satisfy(*args, &block)
    if args.size == 1 && String === args.first
      description = args.shift
    else
      description = ""
    end

    r = yield(@object, *args)
    # TODO not sure if and how we should fix this
    #if Bacon::Counter[:depth] > 0
      raise Bacon::Error.new(:failed, description)  unless @negated ^ r
      r
    #else
      #@negated ? !r : !!r
    #end
  end

  def method_missing(name, *args, &block)
    name = "#{name}?"  if name.to_s =~ /\w[^?]\z/

    desc = @negated ? "not " : ""
    desc << @object.inspect << "." << name.to_s
    desc << "(" << args.map{|x|x.inspect}.join(", ") << ") failed"

    satisfy(desc) { |x| x.__send__(name, *args, &block) }
  end

  def equal(value)         self == value      end
  def match(value)         self =~ value      end
  def identical_to(value)  self.equal? value  end
  alias same_as identical_to

  def flunk(reason="Flunked")
    raise Bacon::Error.new(:failed, reason)
  end
end
