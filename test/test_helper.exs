ExUnit.start()

Code.ensure_loaded!(StrangertalksNew.TurnCredentialTestClient)

Logger.put_module_level(StrangertalksNew.AIService.Client, :info)

Ecto.Adapters.SQL.Sandbox.mode(StrangertalksNew.Repo, :manual)
