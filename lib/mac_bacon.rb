# Bacon -- small RSpec clone.
#
# "Truth will sooner come out from error than from confusion." ---Francis Bacon

# Copyright (C) 2007, 2008 Christian Neukirchen <purl.org/net/chneukirchen>
#
# Bacon is freely distributable under the terms of an MIT-style license.
# See COPYING or http://www.opensource.org/licenses/mit-license.php.

framework "Cocoa"
require "mac_bacon/helpers"

module Bacon
  VERSION = "1.2.1"

  Counter = Hash.new(0)
  ErrorLog = ""
  Shared = Hash.new { |_, name|
    raise NameError, "no such context: #{name.inspect}"
  }

  RestrictName    = //  unless defined? RestrictName
  RestrictContext = //  unless defined? RestrictContext

  Backtraces = true  unless defined? Backtraces

  module SpecDoxOutput
    def handle_specification_begin(name)
      puts spaces + name
    end

    def handle_specification_end
      puts if Counter[:context_depth] == 1
    end

    def handle_requirement_begin(description)
      print "#{spaces}  - #{description}"
    end

    def handle_requirement_end(error)
      puts error.empty? ? "" : " [#{error}]"
    end

    def handle_summary
      print ErrorLog  if Backtraces
      puts "%d specifications (%d requirements), %d failures, %d errors" %
        Counter.values_at(:specifications, :requirements, :failed, :errors)
    end

    def spaces
      "  " * (Counter[:context_depth] - 1)
    end
  end

  module TestUnitOutput
    def handle_specification_begin(name); end
    def handle_specification_end        ; end

    def handle_requirement_begin(description) end
    def handle_requirement_end(error)
      if error.empty?
        print "."
      else
        print error[0..0]
      end
    end

    def handle_summary
      puts "", "Finished in #{Time.now - @timer} seconds."
      puts ErrorLog  if Backtraces
      puts "%d tests, %d assertions, %d failures, %d errors" %
        Counter.values_at(:specifications, :requirements, :failed, :errors)
    end
  end

  module TapOutput
    def handle_specification_begin(name); end
    def handle_specification_end        ; end

    def handle_requirement_begin(description)
      ErrorLog.replace ""
    end

    def handle_requirement_end(error)
      if error.empty?
        puts "ok %-3d - %s" % [Counter[:specifications], description]
      else
        puts "not ok %d - %s: %s" %
          [Counter[:specifications], description, error]
        puts ErrorLog.strip.gsub(/^/, '# ')  if Backtraces
      end
    end

    def handle_summary
      puts "1..#{Counter[:specifications]}"
      puts "# %d tests, %d assertions, %d failures, %d errors" %
        Counter.values_at(:specifications, :requirements, :failed, :errors)
    end
  end

  module KnockOutput
    def handle_specification_begin(name); end
    def handle_specification_end        ; end

    def handle_requirement_begin(description)
      ErrorLog.replace ""
    end

    def handle_requirement_end(error)
      if error.empty?
        puts "ok - %s" % [description]
      else
        puts "not ok - %s: %s" % [description, error]
        puts ErrorLog.strip.gsub(/^/, '# ')  if Backtraces
      end
    end

    def handle_summary;  end
  end

  extend SpecDoxOutput          # default

  class Error < RuntimeError
    attr_accessor :count_as

    def initialize(count_as, message)
      @count_as = count_as
      super message
    end
  end

  class Specification
    attr_reader :description

    def initialize(context, description, block, before_filters, after_filters)
      @context, @description, @block = context, description, block
      @before_filters, @after_filters = before_filters.dup, after_filters.dup

      @postponed_blocks_count = 0
      @exception_occurred = false
      @error = ""
    end

    def run_before_filters
      @before_filters.each { |f| @context.instance_eval(&f) }
    end

    def run_after_filters
      @after_filters.each { |f| @context.instance_eval(&f) }
    end

    def run
      Bacon.handle_requirement_begin(@description)
      execute_block do
        Counter[:depth] += 1
        run_before_filters
        @number_of_requirements_before = Counter[:requirements]
        @context.instance_eval(&@block)
      end

      finish_spec if @postponed_blocks_count == 0
    end

    def schedule_block(seconds, &block)
      # If an exception occurred, we definitely don't need to schedule any more blocks
      unless @exception_occurred
        @postponed_blocks_count += 1
        performSelector("run_postponed_block:", withObject:block, afterDelay:seconds)
      end
    end

    def postpone_block(timeout = 1, &block)
      # If an exception occurred, we definitely don't need to schedule any more blocks
      unless @exception_occurred
        if @postponed_block
          raise "Only one indefinite `wait' block at the same time is allowed!"
        else
          @postponed_blocks_count += 1
          @postponed_block = block
          performSelector("postponed_block_timeout_exceeded", withObject:nil, afterDelay:timeout)
        end
      end
    end

    def postpone_block_until_change(object_to_observe, key_path, timeout = 1, &block)
      # If an exception occurred, we definitely don't need to schedule any more blocks
      unless @exception_occurred
        if @postponed_block
          raise "Only one indefinite `wait' block at the same time is allowed!"
        else
          @postponed_blocks_count += 1
          @postponed_block = block
          object_to_observe.addObserver(self, forKeyPath:key_path, options:0, context:nil)
          performSelector("postponed_change_block_timeout_exceeded:", withObject:[object_to_observe, key_path], afterDelay:timeout)
        end
      end
    end

    def observeValueForKeyPath(key_path, ofObject:object, change:_, context:__)
      object.removeObserver(self, forKeyPath:key_path)
      resume
    end

    def postponed_change_block_timeout_exceeded(object_and_key_path)
      object, key_path = object_and_key_path
      object.removeObserver(self, forKeyPath:key_path)
      postponed_block_timeout_exceeded
    end

    def postponed_block_timeout_exceeded
      NSObject.cancelPreviousPerformRequestsWithTarget(@context)
      NSObject.cancelPreviousPerformRequestsWithTarget(self)
      execute_block { raise "The postponed block timeout has been exceeded." }
      finish_spec
    end

    def resume
      NSObject.cancelPreviousPerformRequestsWithTarget(self, selector:'postponed_block_timeout_exceeded', object:nil)
      block, @postponed_block = @postponed_block, nil
      run_postponed_block(block)
    end

    def run_postponed_block(block)
      # If an exception occurred, we definitely don't need execute any more blocks
      execute_block(&block) unless @exception_occurred
      @postponed_blocks_count -= 1
      finish_spec if @postponed_blocks_count == 0
    end

    def finish_spec
      if !@exception_occurred && Counter[:requirements] == @number_of_requirements_before
        # the specification did not contain any requirements, so it flunked
        # TODO ugh, exceptions for control flow, need to clean this up
        execute_block { raise Error.new(:missing, "empty specification: #{@context.name} #{@description}") }
      end

      execute_block { run_after_filters }

      Counter[:depth] -= 1
      Bacon.handle_requirement_end(@error)
      @context.specification_did_finish(self)
    end

    def execute_block
      begin
        yield
      rescue Object => e
        @exception_occurred = true

        ErrorLog << "#{e.class}: #{e.message}\n"
        e.backtrace.find_all { |line| line !~ /bin\/bacon|\/bacon\.rb:\d+/ }.
          each_with_index { |line, i|
          ErrorLog << "\t#{line}#{i==0 ? ": #{@context.name} - #{@description}" : ""}\n"
        }
        ErrorLog << "\n"

        @error = if e.kind_of? Error
          Counter[e.count_as] += 1
          e.count_as.to_s.upcase
        else
          Counter[:errors] += 1
          "ERROR: #{e.class}"
        end
      end
    end
  end

  def self.add_context(context)
    (@contexts ||= []) << context
  end

  def self.current_context_index
    @current_context_index ||= 0
  end

  def self.current_context
    @contexts[current_context_index]
  end

  def self.run
    @timer ||= Time.now
    Counter[:context_depth] += 1
    handle_specification_begin(current_context.name)
    current_context.performSelector("run", withObject:nil, afterDelay:0)
    NSApplication.sharedApplication.run
  end

  def self.context_did_finish(context)
    handle_specification_end
    Counter[:context_depth] -= 1
    if (@current_context_index + 1) < @contexts.size
      @current_context_index += 1
      run
    else
      # DONE
      handle_summary
      exit(Counter.values_at(:failed, :errors).inject(:+))
    end
  end

  class Context
    attr_reader :name, :block
    
    def initialize(name, before = nil, after = nil, &block)
      @name = name
      @before, @after = (before ? before.dup : []), (after ? after.dup : [])
      @block = block
      @specifications = []
      @current_specification_index = 0

      Bacon.add_context(self)

      instance_eval(&block)
    end

    def run
      # TODO
      #return  unless name =~ RestrictContext
      if spec = current_specification
        spec.performSelector("run", withObject:nil, afterDelay:0)
      else
        Bacon.context_did_finish(self)
      end
    end

    def current_specification
      @specifications[@current_specification_index]
    end

    def specification_did_finish(spec)
      if (@current_specification_index + 1) < @specifications.size
        @current_specification_index += 1
        run
      else
        Bacon.context_did_finish(self)
      end
    end

    def before(&block); @before << block; end
    def after(&block);  @after << block; end

    def behaves_like(*names)
      names.each { |name| instance_eval(&Shared[name]) }
    end

    def it(description, &block)
      return  unless description =~ RestrictName
      block ||= lambda { should.flunk "not implemented" }
      Counter[:specifications] += 1
      @specifications << Specification.new(self, description, block, @before, @after)
    end
    
    def should(*args, &block)
      if Counter[:depth]==0
        it('should '+args.first,&block)
      else
        super(*args,&block)
      end
    end

    def describe(*args, &block)
      context = Bacon::Context.new(args.join(' '), @before, @after, &block)
      (parent_context = self).methods(false).each {|e|
        class<<context; self end.send(:define_method, e) {|*args| parent_context.send(e, *args)}
      }
      context
    end

    def wait(seconds = nil, &block)
      if seconds
        current_specification.schedule_block(seconds, &block)
      else
        current_specification.postpone_block(&block)
      end
    end

    def wait_max(timeout, &block)
      current_specification.postpone_block(timeout, &block)
    end

    def wait_for_change(object_to_observe, key_path, timeout = 1, &block)
      current_specification.postpone_block_until_change(object_to_observe, key_path, timeout, &block)
    end

    def resume
      current_specification.resume
    end

    def raise?(*args, &block); block.raise?(*args); end
    def throw?(*args, &block); block.throw?(*args); end
    def change?(*args, &block); block.change?(*args); end
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
  def should(*args, &block)    Should.new(self).be(*args, &block)         end
end

module Kernel
  private
  def describe(*args, &block) Bacon::Context.new(args.join(' '), &block)  end
  def shared(name, &block)    Bacon::Shared[name] = block                 end
end

class Should
  # Kills ==, ===, =~, eql?, equal?, frozen?, instance_of?, is_a?,
  # kind_of?, nil?, respond_to?, tainted?
  instance_methods.each { |name| undef_method name  if name =~ /\?|^\W+$/ }

  def initialize(object)
    @object = object
    @negated = false
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
    if Bacon::Counter[:depth] > 0
      Bacon::Counter[:requirements] += 1
      raise Bacon::Error.new(:failed, description)  unless @negated ^ r
      r
    else
      @negated ? !r : !!r
    end
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
