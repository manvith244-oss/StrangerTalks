defmodule StrangertalksNew.Experiments.Hearth.Runtime do
  @moduledoc false

  def standalone? do
    Application.get_env(:strangertalks_new, :experiment_hearth_standalone, false) == true or
      System.get_env("EXPERIMENT_HEARTH_STANDALONE", "false") in ["true", "1"]
  end
end
