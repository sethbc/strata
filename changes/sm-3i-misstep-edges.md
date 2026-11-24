### Fixed
- A misstep from a step past the voice's length (a shorter length that has just taken effect) goes to the nearest step inside it: up wraps to step 1, down lands on the length's last step, instead of jumping to a step next to neither (#961).
- In ping-pong a misstep that meets an end now turns there and ends the pass, as an ordinary step does; before, a ping-pong pattern with missteps could wrap past its ends and never end its pass, so a waiting length change, a fill or a pass condition waited for good (#970).
