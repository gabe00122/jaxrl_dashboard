defmodule JaxrlDashboardWeb.ConfigFormTest do
  use ExUnit.Case, async: true

  import JaxrlDashboardWeb.ConfigForm, only: [format_value: 1, input_name: 1]

  test "formats values for inputs" do
    assert format_value(nil) == ""
    assert format_value(512) == "512"
    assert format_value(10_000.0) == "10000.0"
    assert format_value(-1.0) == "-1.0"
    assert format_value(0.0010822848551700177) == "0.0010822848551700177"
    assert format_value(1.0e-8) == "1.0e-8"
    assert format_value("random") == "random"
  end

  test "names inputs after their path" do
    assert input_name(["learner", "model", "obs_encoder", "kernels", 0, 1]) ==
             "config[learner][model][obs_encoder][kernels][0][1]"
  end
end
