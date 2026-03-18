defmodule LemonSim.Examples.Courtroom.CaseGenerator do
  @moduledoc """
  Generates random courtroom trial cases with evidence, witnesses, and case files.

  Each case has a crime, a defendant, a list of evidence items (some incriminating,
  some exculpatory), and witness testimony packets describing what each witness knows.
  """

  @crimes [
    %{
      name: "The Midnight Vault Robbery",
      description:
        "A valuable painting was stolen from the Meridian Museum after hours. " <>
          "The thief disabled the alarm and bypassed three security cameras.",
      defendant: "Alex Vance",
      defendant_role: "museum curator",
      actual_guilty: true
    },
    %{
      name: "The Poisoned Partnership",
      description:
        "Reginald Frost was found dead at his desk, poisoned. " <>
          "His business partner stands accused of the murder to gain sole ownership of the firm.",
      defendant: "Dana Holloway",
      defendant_role: "business partner",
      actual_guilty: false
    },
    %{
      name: "The Embezzled Endowment",
      description:
        "Funds from the Westbrook Charity Foundation went missing over eighteen months. " <>
          "The foundation's director is charged with embezzling three million dollars.",
      defendant: "Marcus Leigh",
      defendant_role: "foundation director",
      actual_guilty: true
    },
    %{
      name: "The Sabotaged Software",
      description:
        "A competitor's product launch was derailed by malicious code inserted into their build pipeline. " <>
          "The accused is a former employee with both the motive and technical access.",
      defendant: "Sofia Tran",
      defendant_role: "software engineer",
      actual_guilty: false
    }
  ]

  @evidence_templates %{
    "fingerprints_at_scene" => %{
      description: "Fingerprints matching the defendant found at the crime scene",
      incriminating: true
    },
    "alibi_receipt" => %{
      description: "Timestamped receipt placing defendant at a restaurant during the crime",
      incriminating: false
    },
    "security_footage" => %{
      description: "Security camera footage showing a figure matching defendant's build",
      incriminating: true
    },
    "deleted_emails" => %{
      description: "Recovered deleted emails discussing the alleged crime",
      incriminating: true
    },
    "character_witness_letter" => %{
      description: "Letter from a community leader attesting to defendant's good character",
      incriminating: false
    },
    "financial_records" => %{
      description: "Bank records showing suspicious transfers matching the crime timeline",
      incriminating: true
    },
    "dna_sample" => %{
      description: "DNA trace evidence collected from the crime scene",
      incriminating: true
    },
    "witness_statement_prior" => %{
      description: "A prior written statement from a witness that contradicts their current testimony",
      incriminating: false
    },
    "phone_records" => %{
      description: "Call logs showing contact between defendant and an accomplice",
      incriminating: true
    },
    "medical_report" => %{
      description: "Medical report documenting the victim's condition inconsistent with defendant's account",
      incriminating: true
    },
    "expert_analysis" => %{
      description: "Forensic expert analysis casting doubt on the prosecution's physical evidence",
      incriminating: false
    },
    "motive_document" => %{
      description: "Document establishing clear financial motive for the alleged crime",
      incriminating: true
    }
  }

  @witness_archetypes [
    %{
      name: "eyewitness",
      description: "Claims to have witnessed the event directly",
      reliability: :partial
    },
    %{
      name: "expert",
      description: "Forensic or technical expert providing scientific analysis",
      reliability: :high
    },
    %{
      name: "character",
      description: "Personal acquaintance speaking to the defendant's character",
      reliability: :low
    }
  ]

  @spec generate(keyword()) :: map()
  def generate(opts \\ []) do
    seed = Keyword.get(opts, :seed, :erlang.phash2(:erlang.monotonic_time()))
    :rand.seed(:exsss, {seed, seed + 1, seed + 2})

    crime = Enum.random(@crimes)
    evidence_count = Keyword.get(opts, :evidence_count, 6)
    witness_count = Keyword.get(opts, :witness_count, 3)

    evidence_list = generate_evidence(evidence_count)
    witnesses = generate_witnesses(witness_count, crime, evidence_list)

    %{
      title: crime.name,
      description: crime.description,
      defendant: crime.defendant,
      defendant_role: crime.defendant_role,
      actual_guilty: crime.actual_guilty,
      evidence_list: evidence_list,
      evidence_details: Map.take(@evidence_templates, evidence_list),
      witnesses: witnesses,
      planted_evidence: pick_planted_evidence(evidence_list, crime.actual_guilty)
    }
  end

  @spec evidence_summary(map()) :: String.t()
  def evidence_summary(case_file) do
    evidence_list = Map.get(case_file, :evidence_list, [])
    evidence_details = Map.get(case_file, :evidence_details, %{})

    evidence_list
    |> Enum.map(fn id ->
      info = Map.get(evidence_details, id, %{})
      desc = Map.get(info, :description, id)
      "- #{id}: #{desc}"
    end)
    |> Enum.join("\n")
  end

  @spec witness_testimony_packet(map(), String.t()) :: String.t()
  def witness_testimony_packet(case_file, witness_id) do
    witnesses = Map.get(case_file, :witnesses, %{})
    witness = Map.get(witnesses, witness_id, %{})
    archetype = Map.get(witness, :archetype, "witness")
    testimony = Map.get(witness, :testimony, "I don't recall anything relevant.")
    knows_evidence = Map.get(witness, :knows_evidence, [])

    """
    Your role: #{archetype}
    Your testimony knowledge: #{testimony}
    Evidence you are aware of: #{Enum.join(knows_evidence, ", ")}

    Answer questions truthfully based on what you know.
    If asked about evidence you don't know, say so.
    """
  end

  # -- Private helpers --

  defp generate_evidence(count) do
    all_evidence = Map.keys(@evidence_templates)
    count = min(count, length(all_evidence))
    Enum.take(Enum.shuffle(all_evidence), count)
  end

  defp generate_witnesses(count, crime, evidence_list) do
    count = min(count, length(@witness_archetypes))
    archetypes = Enum.take(Enum.shuffle(@witness_archetypes), count)

    archetypes
    |> Enum.with_index(1)
    |> Enum.into(%{}, fn {archetype, idx} ->
      witness_id = "witness_#{idx}"
      knows = Enum.take(Enum.shuffle(evidence_list), div(length(evidence_list), 2))

      testimony = generate_testimony(archetype, crime, knows)

      {witness_id,
       %{
         archetype: archetype.name,
         reliability: archetype.reliability,
         testimony: testimony,
         knows_evidence: knows
       }}
    end)
  end

  defp generate_testimony(%{name: "eyewitness"}, crime, _knows) do
    "I saw someone matching the description of #{crime.defendant} near the scene. " <>
      "I cannot be 100% certain it was them, but their build and gait were distinctive."
  end

  defp generate_testimony(%{name: "expert"}, _crime, knows) do
    "My forensic analysis of the evidence — specifically #{Enum.join(Enum.take(knows, 2), " and ")} — " <>
      "reveals patterns consistent with the prosecution's timeline, though there are alternative explanations."
  end

  defp generate_testimony(%{name: "character"}, crime, _knows) do
    "I have known #{crime.defendant} for many years. " <>
      "They are a person of integrity and I find these charges deeply inconsistent with their character."
  end

  defp generate_testimony(_archetype, crime, _knows) do
    "I have limited knowledge of #{crime.defendant}'s activities during the relevant period."
  end

  defp pick_planted_evidence(evidence_list, actual_guilty) do
    # If defendant is actually guilty, some exculpatory evidence was planted
    # If defendant is innocent, some incriminating evidence was planted
    planted_type = if actual_guilty, do: false, else: true

    evidence_list
    |> Enum.filter(fn id ->
      info = Map.get(@evidence_templates, id, %{})
      Map.get(info, :incriminating, false) == planted_type
    end)
    |> Enum.take(1)
  end
end
