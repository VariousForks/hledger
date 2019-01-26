Shell completion for CLI
========================

This code generates shell completion scripts for hledger's command line
interface.
Shell completion is usually triggered by pressing the tab key once or twice
after typing the command `hledger `.
(The exact behavior may differ in shells other than Bash.)

Currently, only Bash is supported but Zsh or Fish can be added.

[Demonstration video](https://asciinema.org/a/PdV2PzIU9oDQg1K5FjAX9n3vL)

The completions can handle hledger's CLI:

- commands and generic options
- command-specific options
- filenames for options that take a filename as argument
- account names from journal files (but not yet for files named by `--file`)
- query filter keywords like `status:`, `tag:`, or `amt:`

Installation for end users
--------------------------

Completions are currently only implemented for the Bash shell.

Please check first if the completions for hledger are already installed on your
distribution. Refer to the last paragraph of this section for how to test that.

To install the completions manually, follow this steps:

- Download or copy the file `shell-completion/hledger-completion.bash` and save
  it as `~/.hledger-completion.bash`.

- Add the command `'source ~/.hledger-completion.bash'` this to the end of your
  `~/.bashrc` file.

- Then, you have to start a new Bash, e.g. by typing `bash` on the current
  shell.

Example installation script:

```
cp hledger-completion.bash ~/.hledger-completion.bash
echo 'source ~/.hledger-completion.bash' >> ~/.bashrc
```

Now, try it by typing `hledger` (with a space after the command) and press the
tab key twice. You should see a list of appropriate completions for hledger.
Then you can type a part of one of the suggestions and press tab again to
complete it.

Background
----------

The Bash completion script is generated (GNU make) by parsing output of `hledger`,
`hledger -h`, and `hledger <cmd> -h`. The script also uses `hledger accounts` for
account name completion. I propose that the Makefile is not run at every built
but rather manually when the CLI changes.

Information for developers
--------------------------

Generate the completion script for Bash:

```
# change into this folder:
cd shell-completion/
make
```

Hint: GNU make, GNU m4, and GNU parallel must be installed to call `make`.
The first two usually are.

The generated completion script must be installed. The package maintainer for
your distribution should be responsible for this.

For now, or to live-test the script, you can use these two commands:

```
ln -s hledger-completion.bash ~/.hledger-completion.bash
echo 'source ~/.hledger-completion.bash' >> ~/.bashrc
```

After that, you have to start a new Bash, e.g. by typing `bash` on the current
shell.

Now, try it by typing `hledger` (with a space after the command) and press the
tab key twice. You know how completions work – if not, see above in the
Installation section.

Completion scripts for other shells (e.g. Fish or Zsh)
------------------------------------------------------

You're welcome to add completion scripts for other shells. It should not be too
hard! All available hledger options and commands are already there (generated by
the Makefile).

The generated text files with options and commands are: `commands.txt`,
`generic-options.txt`, and `options-*.txt` where `*` is the subcommand.

Instructions to add support for another shell:

1. Create e.g. `hledger-completion.fish.m4` as a template file.

2. Add a Make rule to transform it to `hledger-completion.fish`.

3. Use m4 commands to include hledger options and commands into your script
   template. See `hledger-completion.bash.m4` as a reference.

4. Use `make` and then `make hledger-completion.fish` to create and test the
   completion script.

5. Finally, if everything is working, also add the generated artifact
   `hledger-completion.fish` to the repo so that people can use it directly.