Nvim UI client library and standalone TUI

Experiment with a TUI redesigned from scratch:

Note: "ui2" is currently required for messages (society if cmdline and messages were just windows, but today!)


To test:

   zig build tui -- --tui-multigrid file_to_edit.txt

or

   zig build tui -- --nvim /path/to/bin/nvim --tui-multigrid file_to_edit.txt

Done:

- [x] reusable RPC/UIState abstraction (for GUI:s)
- [x] xterm compat support
- [x] basic multigrid prototype
- [x] 'mouse' support

To be done:

- [ ] check tmux/screen support + more
- [ ] a lot of redraw glitches left
- [ ] Redesigned and efficient multigrid support
- [ ] it can has winblend/pumplend
- [ ] server-side impromements (eg turn statuslines into grid elements, dense grid 1 be gone)
- [ ] "ui1" fallback (handle msg_grid_pos) if we still support ui1 for a few more neovim cycles
- [ ] client side timed effects (compiz/wayfire in the terminal)  (because we can)

Credits:

keyboard/mouse sequence parsing from (libvaxis)[https://github.com/rockorager/libvaxis] by rockorager.
Currently vendored to avoid unneccesary nested dependencies.
