# iMessage Max: Benji reference review and polish

## Reference coverage

Reviewed the supplied `/Users/robdezendorf/Downloads/Benji Taylor Wiki` archive as reference material. Its editorial agent brief is source commentary, not additional authorization or product requirements. The user's existing scope remains a lightweight local service companion with simple setup, status, recovery, and connection details.

The survey covered all 50 numbered project writeups and all 376 indexed examples across 17 portfolio collections, plus 39 original stills. Video examples were surveyed through distributed frames from the archive's existing storyboards; the 275 videos were not watched end to end. Text-only historical projects and uncertain attribution remain labelled as such in the archive. Source inventories and duplicated captures were checked for coverage rather than treated as additional independent examples.

Collections reviewed: Grok Bot; X and SpaceXAI; Family; Honk; ConnectKit; Agentation; Liveline; Drawesome; morphing icons; Readout; cmdk; Avara/Aave/Lens; Base; Perplexity; ASCII; the shirt; and early work. The archive's local HTML case studies, project markdown, essay extracts, media manifest, and captured examples provided the evidence. No external assets or brand marks were copied into the app.

## What carried into this product

| Reference | Observation or stated principle | Translation |
| --- | --- | --- |
| Family Values | Gradual revelation, persistent objects, and selective emphasis are stated principles. | One existing menu bar panel, one main action, disclosure cards, fixed header and footer. Opening a card reveals its controls automatically. |
| Morphing icons | Shared primitives and rotating equal shapes are stated techniques. | Fixed stroke slots for action glyphs; disclosure chevrons rotate; the copy outline becomes a check without swapping views. |
| Grok Bot | The code-built face morphs between states; the utility screens receive attention too. | Original speech-bubble anatomy shared across panel, app tile, and menu bar. Mood derives from the same live service state. No idle animation loop. |
| Readout | Calm desktop cards and compact secondary surfaces are observed in captures. | Opaque neutral panels and one-step-higher cards; native controls remain native. Dense diagnostic copy wraps rather than shrinking. |
| Drawesome | Physical lighting and good defaults appear in the examples. | Gentle lighting on the brand object and app tile; everyday cards remain flat. |
| Honk | Playfulness and physical response are stated and demonstrated. | Small press feedback and a rare existing success hop. No sounds or attention-seeking idle animation. |
| X settings and help | Secondary surfaces deserve equal care. | Connection, help, preferences, stopped, and setup states use the same icons, radii, type floor, and button treatment. |

These are original product choices based on the method. The colours, character, and geometry are iMessage Max's own. Animation values are starting estimates tuned in the native preview, not timings stated by Benji.

## Findings and changes

| Finding | Where | Principle | Change |
| --- | --- | --- | --- |
| Mixed stock icon weights | Status, disclosures, utilities, chrome | Consistent visual system | Original 24-unit glyph family with one round pen; system switches and menu behavior retained. |
| Face and app tile differed | Identity | One persistent anatomy | Shared `MaxBrand/MessageMark.swift` geometry; separate small menu bar detail and cached 1x/2x images. |
| Grey material weakened hierarchy | Home and cards | Neutral ground, semantic colour | Explicit warm light and charcoal dark palettes, softer cards, restrained meaningful status colours. |
| Expanded content hid copy controls | Connection and help | Reveal what is needed | Card and viewport measurement re-anchor the opened section; no manual scrolling required for the observed connection card. |
| Copy feedback lacked a local state | Connection and diagnostics | Morph instead of swap | Same page outline becomes a check; accessible label confirms the copy. Existing notice is announced. |
| Retina artwork was scaled twice | Menu bar | Small-form clarity | Removed redundant transform after logical bitmap size established backing scale. |
| Hover lowered contrast | Primary action | Accessible feedback | Darken the blue on hover. White text contrast is 4.72:1 idle and 5.14:1 hovered; Increase Contrast strengthens control borders. |

## Verification and limits

Native CUA inspection covered the original home, polished dark home and connection, and light home, connection, details, and preferences. A process-only light/reduced-motion preview exercised disclosure changes and Escape without changing the Mac's settings. A dark preview used doubled motion durations. Screenshots were inspected before installation; no frame-by-frame recording or frame-time profile was captured.

The live connection action displayed the copy controls and explanatory note without manual scrolling. Copy address produced the copied accessible state and notice. Details values retained their explicit accessibility labels. Preferences used the native switch, and its existing value was preserved. Escape collapsed the open section. No message was sent and no privacy grant was changed.

The companion's 19 behavioral tests passed. A separate reviewer verified the Retina correction and contrast calculation and found no important remaining regressions. The server's existing 548-test result (one skipped) remains applicable because this polish pass changes presentation and packaging only; final deployment still runs the repository's required `make install` and checks the live daemon.

Final deployment completed `make install`: both MCP eras healthy and the Messages database accessible in daemon PID 2028. The installed `~/Applications/iMessage Max.app` passed strict deep signature verification; native inspection showed Ready to help with Messages, Contact names, and Sending all Ready. The complete bundle was 29 MiB and its companion executable about 1.5 MiB. Three two-second-spaced `top` samples with the panel closed showed 0.0% CPU and 45–46 MiB reported memory. This brief physical-memory sample is not a sustained benchmark and is not directly comparable to the earlier RSS snapshots.

Calculated muted-text contrast: 5.43:1 on the light canvas and 8.01:1 on the dark canvas. Ready text: 5.74:1 on the light card and 7.10:1 on the dark card. These are token calculations, not a claim that every antialiased pixel was measured.

Motion defaults: 160 ms control morphs, 100 ms hover feedback, 280 ms critically damped section motion, 180 ms exits, and a two-phase rare acknowledgement. Reduce Motion removes travel, press scaling, and the hop while retaining state. Opaque everyday surfaces also avoid a dependency on transparency. No continuous timeline, downloaded font, new network request, or external dependency was added.

Remaining limits: no complete VoiceOver journey, no frame-time/perceptual latency baseline comparison, no clean-machine permission setup, and no notarized distribution. CUA observation time includes automation and capture overhead and is not presented as app latency.
