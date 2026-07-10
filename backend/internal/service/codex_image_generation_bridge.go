package service

import "strings"

const featureKeyCodexImageGenerationBridge = "codex_image_generation_bridge"

const (
	featureKeyCodexImageGenerationExplicitToolPolicy = "codex_image_generation_explicit_tool_policy"
	featureKeyOpenAIImagesStreamMode                 = "openai_images_stream_mode"

	codexImageGenerationExplicitToolPolicyAllow = "allow"
	codexImageGenerationExplicitToolPolicyStrip = "strip"

	openAIImagesStreamModeClient      = "client"
	openAIImagesStreamModeForceStream = "force_stream"
)

func boolOverridePtr(v bool) *bool {
	return &v
}

func boolOverrideFromMap(values map[string]any, keys ...string) *bool {
	if values == nil {
		return nil
	}
	for _, key := range keys {
		if v, ok := values[key].(bool); ok {
			return boolOverridePtr(v)
		}
	}
	return nil
}

func stringOverrideFromMap(values map[string]any, keys ...string) (string, bool) {
	if values == nil {
		return "", false
	}
	for _, key := range keys {
		if v, ok := values[key].(string); ok {
			return v, true
		}
	}
	return "", false
}

func normalizeCodexImageGenerationExplicitToolPolicy(value string) string {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case codexImageGenerationExplicitToolPolicyStrip, "remove", "drop":
		return codexImageGenerationExplicitToolPolicyStrip
	default:
		return codexImageGenerationExplicitToolPolicyAllow
	}
}

func normalizeOpenAIImagesStreamMode(value string) string {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case openAIImagesStreamModeForceStream, "force", "forced", "stream", "on", "enabled", "true":
		return openAIImagesStreamModeForceStream
	default:
		return openAIImagesStreamModeClient
	}
}

func platformBoolOverride(values map[string]any, key string, platform string) *bool {
	if values == nil {
		return nil
	}
	if v, ok := values[key].(bool); ok {
		return boolOverridePtr(v)
	}
	raw, ok := values[key].(map[string]any)
	if !ok {
		return nil
	}
	platform = strings.TrimSpace(platform)
	if platform == "" {
		return nil
	}
	if v, ok := raw[platform].(bool); ok {
		return boolOverridePtr(v)
	}
	return nil
}

// CodexImageGenerationBridgeOverride returns the channel-level override for Codex
// image_generation bridge injection. Nil means follow the global/account policy.
func (c *Channel) CodexImageGenerationBridgeOverride(platform string) *bool {
	if c == nil {
		return nil
	}
	return platformBoolOverride(c.FeaturesConfig, featureKeyCodexImageGenerationBridge, platform)
}

// CodexImageGenerationBridgeOverride returns the account-level override for Codex
// image_generation bridge injection. Nil means follow the channel/global policy.
func (a *Account) CodexImageGenerationBridgeOverride() *bool {
	if a == nil || a.Platform != PlatformOpenAI || a.Extra == nil {
		return nil
	}
	if override := boolOverrideFromMap(a.Extra, featureKeyCodexImageGenerationBridge, "codex_image_generation_bridge_enabled"); override != nil {
		return override
	}
	openaiConfig, _ := a.Extra[PlatformOpenAI].(map[string]any)
	return boolOverrideFromMap(openaiConfig, featureKeyCodexImageGenerationBridge, "codex_image_generation_bridge_enabled")
}

// CodexImageGenerationExplicitToolPolicy returns the account-level policy for
// client-provided Codex /responses image_generation tools. Unknown or unset
// values default to allow to preserve existing behavior.
func (a *Account) CodexImageGenerationExplicitToolPolicy() string {
	if a == nil || a.Platform != PlatformOpenAI || a.Extra == nil {
		return codexImageGenerationExplicitToolPolicyAllow
	}
	if policy, ok := stringOverrideFromMap(a.Extra, featureKeyCodexImageGenerationExplicitToolPolicy); ok {
		return normalizeCodexImageGenerationExplicitToolPolicy(policy)
	}
	openaiConfig, _ := a.Extra[PlatformOpenAI].(map[string]any)
	if policy, ok := stringOverrideFromMap(openaiConfig, featureKeyCodexImageGenerationExplicitToolPolicy); ok {
		return normalizeCodexImageGenerationExplicitToolPolicy(policy)
	}
	return codexImageGenerationExplicitToolPolicyAllow
}

// OpenAIImagesStreamMode controls how `/v1/images/*` requests use upstream
// streaming. The default client mode preserves the caller's `stream` field.
func (a *Account) OpenAIImagesStreamMode() string {
	if a == nil || a.Platform != PlatformOpenAI || a.Extra == nil {
		return openAIImagesStreamModeClient
	}
	if mode, ok := stringOverrideFromMap(a.Extra, featureKeyOpenAIImagesStreamMode, "openai_image_stream_mode"); ok {
		return normalizeOpenAIImagesStreamMode(mode)
	}
	if override := boolOverrideFromMap(a.Extra, "openai_images_force_stream", "openai_image_force_stream"); override != nil {
		if *override {
			return openAIImagesStreamModeForceStream
		}
		return openAIImagesStreamModeClient
	}
	openaiConfig, _ := a.Extra[PlatformOpenAI].(map[string]any)
	if mode, ok := stringOverrideFromMap(openaiConfig, featureKeyOpenAIImagesStreamMode, "openai_image_stream_mode"); ok {
		return normalizeOpenAIImagesStreamMode(mode)
	}
	if override := boolOverrideFromMap(openaiConfig, "openai_images_force_stream", "openai_image_force_stream"); override != nil {
		if *override {
			return openAIImagesStreamModeForceStream
		}
	}
	return openAIImagesStreamModeClient
}

func (a *Account) ForceOpenAIImagesStream() bool {
	return a.OpenAIImagesStreamMode() == openAIImagesStreamModeForceStream
}
