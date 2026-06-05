defmodule Tracy.LLM.Message do
  @moduledoc """
  Pure data type for a conversation message.

  Decoupled from any provider's wire format. Adapters (Claude, Stub, future
  local impls) translate to/from their native shapes at the seam.
  """

  @type role :: :system | :user | :assistant
  @type t :: %__MODULE__{
          role: role(),
          content: String.t(),
          metadata: map()
        }

  @enforce_keys [:role, :content]
  defstruct [:role, :content, metadata: %{}]

  @spec system(String.t(), map()) :: t()
  def system(content, metadata \\ %{}),
    do: %__MODULE__{role: :system, content: content, metadata: metadata}

  @spec user(String.t(), map()) :: t()
  def user(content, metadata \\ %{}),
    do: %__MODULE__{role: :user, content: content, metadata: metadata}

  @spec assistant(String.t(), map()) :: t()
  def assistant(content, metadata \\ %{}),
    do: %__MODULE__{role: :assistant, content: content, metadata: metadata}
end
