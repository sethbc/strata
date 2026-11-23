### Fixed
- A long file (high tier) whose check hits an error in the engine is reported as a failed load, so its slot no longer shows `...` until you load or clear it.
- Lifting the delay's bypass after a freeze no longer brings the delay back frozen and silent: it comes back unfrozen at its time.
- A bad file loaded in the moment just after a take ends no longer throws the finished take away, for a take stopped with K3 as for one that ran to its length; a clear or a new recording then counts the take as ended, not canceled.
- A slot being loaded stays at the norns rate until its length arrives, so nothing reads it at the new file's rate while it is still empty.
