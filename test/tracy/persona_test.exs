defmodule Tracy.PersonaTest do
  use ExUnit.Case, async: true

  alias Tracy.Persona

  test "name is Tracy" do
    assert Persona.name() == "Tracy"
  end

  describe "base/0" do
    setup do
      %{prompt: Persona.base()}
    end

    test "identifies as Tracy, not as an AI assistant", %{prompt: p} do
      assert p =~ "You are Tracy"
      # The phrase as a self-disclaimer is what we don't want, not the
      # literal substring (the prompt teaches it NOT to say "As an AI, I").
      refute p =~ "I'm an AI and"
      refute p =~ "As a large language model"
    end

    test "encodes the voice directives", %{prompt: p} do
      assert p =~ "First-person singular"
      assert p =~ "Direct, concise, opinionated"
      assert p =~ "Match Matt's energy"
      assert p =~ "Lead with the outcome"
    end

    test "encodes the no-push constraint", %{prompt: p} do
      assert p =~ "Don't push to remote"
    end

    test "encodes Conventional Commits + Tracy-Task trailer", %{prompt: p} do
      assert p =~ "Conventional Commits"
      assert p =~ "Tracy-Task"
    end

    test "encodes the budget gate thresholds", %{prompt: p} do
      assert p =~ "75%"
      assert p =~ "85%"
    end

    test "encodes the JARVIS / one-brain frame", %{prompt: p} do
      assert p =~ "JARVIS"
      assert p =~ "You ARE Tracy"
    end
  end

  describe "system_prompt/1" do
    test "base only when no context given" do
      assert Persona.system_prompt() == Persona.base()
    end

    test "appends pinned project line when project given" do
      prompt = Persona.system_prompt(project: "Tracy")
      assert prompt =~ "Pinned project: **Tracy**"
    end

    test "appends cost zone when cost_state given" do
      prompt = Persona.system_prompt(cost_state: %{pct: 78.5, zone: :winddown})
      assert prompt =~ "78.5%"
      assert prompt =~ "wind-down"
    end

    test "lists in-flight workers when given" do
      prompt = Persona.system_prompt(in_flight_workers: ["engineer:favicon", "designer:logo-v2"])
      assert prompt =~ "Workers in flight: 2"
      assert prompt =~ "engineer:favicon"
      assert prompt =~ "designer:logo-v2"
    end
  end
end
