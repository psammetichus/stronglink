StrongLink Installation Guide
=============================

Warning: Not for the faint of heart! This process will be streamlined over time. The eventual goal is to have native GUI apps and one-click web hosting. For now, it will take some elbow grease.

Dependencies
------------

Most of the dependencies are included. You might need to instal Git to clone the repository, or you can use GitHub's ZIP download.

Additional dependencies:

Ubuntu / Debian / Linux Mint: `sudo apt-get install gcc g++ gobjc cmake automake autoconf libtool pkg-config libssl-dev`

Fedora / RedHat: `sudo yum install gcc gcc-c++ gcc-objc cmake automake autoconf libtool openssl-devel`

OS X: Install the developer tools from the App Store and cmake from Homebrew. [TODO]

Windows: untested, probably needs work

You can substitute Clang for GCC if you prefer.

A semi-recent version of [Node.js](https://nodejs.org/) or [io.js](https://iojs.org/) is required for the Node example scripts including `sln-pipe`.

Basic Installation
------------------

1. `./configure && make`
2. `sudo make install`
3. `stronglink /repo-dir`

Server Configuration
--------------------

Right now there is no configuration interface whatsoever (not even a config file). That means you need to edit the code and recompile to change any settings.

- Port number: set `SERVER_PORT` in `src/blog/main.c`
- Server access: set `SERVER_ADDRESS` in `src/blog/main.c`
- Database backend: use `DB=xx make` where `xx` is empty (for LevelDB), `mdb`, `rocksdb`, or `hyper`
- Repository name: uses the repository directory's basename
- Guest access: set `repo->pub_mode` from `0` to `SLN_RDONLY` or `SLN_RDWR`
- Number of results per page: `RESULTS_MAX` in `src/blog/Blog.c`

Client Configuration
--------------------

Clients (for example the Node example scripts) are configured through a JSON file located at `~/.config/stronglink/client.json`. That config file looks something like this:

```json
{
	"repos": {
		"main": {
			"url": "http://localhost:8000/",
			"session": "[...]"
		}
	}
}
```

Currently there is no interface for managing session keys. The only way to get one is by logging into the blog interface using a web browser or a tool like cURL and checking the cookie that is sent back.

You can set up any number of repositories and the names (like "main" above) are up to you.

