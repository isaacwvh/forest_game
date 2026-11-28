package server

import "encoding/json"

// Published rule documents can omit defaults. Populate the same defaults that
// the reference API emits when constructing skill DTOs for the iOS client.
func skillEffectWire(effect map[string]json.RawMessage) error {
	fillSkillDefaults(effect, map[string]json.RawMessage{
		"componentVersion": []byte(`1`), "minimumStage": []byte(`"adult"`), "operation": []byte(`"percent"`),
		"stackingRule": []byte(`"strongest"`), "metric": []byte(`null`), "recipients": []byte(`null`), "condition": []byte(`null`),
	})
	if err := skillSelectorWire(effect, "recipients"); err != nil {
		return err
	}
	for key, defaults := range map[string]map[string]json.RawMessage{
		"condition": {"type": []byte(`"placed_count"`), "minimum": []byte(`1`)},
		"magnitude": {"type": []byte(`"fixed"`), "selector": []byte(`null`), "maximum": []byte(`null`)},
	} {
		raw := effect[key]
		if len(raw) == 0 || string(raw) == "null" {
			continue
		}
		var part map[string]json.RawMessage
		if err := json.Unmarshal(raw, &part); err != nil {
			return err
		}
		fillSkillDefaults(part, defaults)
		if err := skillSelectorWire(part, "selector"); err != nil {
			return err
		}
		encoded, err := json.Marshal(part)
		if err != nil {
			return err
		}
		effect[key] = encoded
	}
	return nil
}

func fillSkillDefaults(value, defaults map[string]json.RawMessage) {
	for key, fallback := range defaults {
		if _, present := value[key]; !present {
			value[key] = fallback
		}
	}
}

func skillSelectorWire(parent map[string]json.RawMessage, key string) error {
	raw := parent[key]
	if len(raw) == 0 || string(raw) == "null" {
		return nil
	}
	var selector map[string]json.RawMessage
	if err := json.Unmarshal(raw, &selector); err != nil {
		return err
	}
	for _, field := range []string{"species", "variants", "stages", "tags"} {
		if _, present := selector[field]; !present {
			selector[field] = json.RawMessage(`[]`)
		}
	}
	data, err := json.Marshal(selector)
	parent[key] = data
	return err
}

func plantSkillWire(raw json.RawMessage) (json.RawMessage, error) {
	if len(raw) == 0 || string(raw) == "null" || string(raw) == "[]" {
		return json.RawMessage(`[]`), nil
	}
	var effects []map[string]json.RawMessage
	if err := json.Unmarshal(raw, &effects); err != nil {
		return nil, err
	}
	for _, effect := range effects {
		if effect == nil {
			return nil, invalidSkills
		}
		if err := skillEffectWire(effect); err != nil {
			return nil, err
		}
	}
	return json.Marshal(effects)
}

func plantDocumentWire(raw json.RawMessage) (json.RawMessage, error) {
	var plant struct {
		Skills json.RawMessage `json:"gardenSkills"`
	}
	if err := json.Unmarshal(raw, &plant); err != nil {
		return nil, err
	}
	if len(plant.Skills) == 0 || string(plant.Skills) == "[]" {
		return raw, nil
	}
	skills, err := plantSkillWire(plant.Skills)
	if err != nil {
		return nil, err
	}
	return setPlantSkills(raw, skills)
}

func setPlantSkills(raw, skills json.RawMessage) (json.RawMessage, error) {
	var plant map[string]json.RawMessage
	if err := json.Unmarshal(raw, &plant); err != nil {
		return nil, err
	}
	plant["gardenSkills"] = skills
	return json.Marshal(plant)
}
