describe "NSRunloop aware Bacon" do
  it "allows the user to postpone execution of a block for n seconds, which will halt any further execution of specs" do
    started_at_1 = started_at_2 = started_at_3 = Time.now
    number_of_specs_before = Bacon::Counter[:specifications]

    wait 0.5 do
      (Time.now - started_at_1).should.be.close(0.5, 0.01)
    end
    wait 1 do
      (Time.now - started_at_2).should.be.close(1, 0.01)
      wait 1.5 do
        (Time.now - started_at_3).should.be.close(2.5, 0.01)
        Bacon::Counter[:specifications].should == number_of_specs_before
      end
    end
  end
end

