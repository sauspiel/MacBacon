$:.unshift File.expand_path('../../lib', __FILE__)
require 'mac_bacon'

module Bacon
  class Specification
    alias_method :_real_finish_spec, :finish_spec
  end

  class Context
    def failures_before
      @failures_before
    end

    def expect_spec_to_fail!
      @failures_before = Bacon::Counter[:failures]
      Bacon::Specification.class_eval do
        def finish_spec
          @exception_occurred.should == true
          @exception_occurred = nil
          Bacon::Counter[:errors].should == @context.failures_before + 1
          Bacon::Counter[:errors] = @context.failures_before
          self.class.class_eval { alias_method :finish_spec, :_real_finish_spec }
          _real_finish_spec
        end
      end
    end
  end
end
