defmodule StrangertalksNewWeb.ReflectionJSON do
  def index(%{reflections: reflections}) do
    %{reflections: Enum.map(reflections, &data/1)}
  end

  def show(%{reflection: reflection}) do
    %{reflection: data(reflection)}
  end

  def show(%{status: status, reflection: reflection}) do
    %{status: status, reflection: data(reflection)}
  end

  def data(reflection) do
    %{
      reflection_id: reflection.reflection_id,
      own_reflection_text: reflection.own_reflection_text,
      source_excerpt: reflection.source_excerpt,
      revision: reflection.revision,
      create_operation_id: reflection.create_operation_id,
      saved_at: DateTime.to_iso8601(reflection.saved_at),
      updated_at: DateTime.to_iso8601(reflection.updated_at)
    }
  end
end
