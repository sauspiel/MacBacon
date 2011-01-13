require File.expand_path('../spec_helper', __FILE__)

describe "NSRunloop aware Bacon" do
  it "allows the user to postpone execution of a block for n seconds, which will halt any further execution of specs" do
    started_at_1 = started_at_2 = started_at_3 = Time.now
    number_of_specs_before = Bacon::Counter[:specifications]

    wait 0.5 do
      (Time.now - started_at_1).should.be.close(0.5, 0.5)
    end
    wait 1 do
      (Time.now - started_at_2).should.be.close(1, 0.5)
      wait 1.5 do
        (Time.now - started_at_3).should.be.close(2.5, 0.5)
        Bacon::Counter[:specifications].should == number_of_specs_before
      end
    end
  end
end

class WindowController < NSWindowController
  attr_accessor :arrayController
  attr_accessor :tableView
  attr_accessor :textField
end

describe "Nib helper" do
  def verify_outlets_of_owner(owner)
    owner.arrayController.should.be.instance_of NSArrayController
    owner.tableView.should.be.instance_of NSTableView
    owner.textField.should.be.instance_of NSTextField
  end

  it "takes a NIB path and instantiates the NIB with the given `owner' object" do
    nib_path = File.expand_path("../fixtures/Window.nib", __FILE__)
    owner = WindowController.new
    load_nib(nib_path, owner)
    verify_outlets_of_owner(owner)
  end

  it "also returns an array or other top level objects" do
    nib_path = File.expand_path("../fixtures/Window.nib", __FILE__)
    owner = WindowController.new
    top_level_objects = load_nib(nib_path, owner).sort_by { |o| o.class.name }
    top_level_objects[0].should.be.instance_of NSApplication
    top_level_objects[1].should.be.instance_of NSArrayController
    top_level_objects[2].should.be.instance_of NSWindow
  end

  it "converts a XIB to a tmp NIB before loading it and caches it" do
    xib_path = File.expand_path("../fixtures/Window.xib", __FILE__)
    owner = WindowController.new
    load_nib(xib_path, owner)
    verify_outlets_of_owner(owner)

    def self.system(cmd)
      raise "Oh noes! Tried to convert again!"
    end

    owner = WindowController.new
    load_nib(xib_path, owner)
    verify_outlets_of_owner(owner)
  end
end
