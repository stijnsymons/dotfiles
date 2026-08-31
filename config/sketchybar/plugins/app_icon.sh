#!/usr/bin/env bash
# Nerd Font glyph per app (front_app_switched name, or bundle id).
# Glyph map lifted from the previous rift_workspaces.sh so the icons stay yours.
# Sourced, not executed: `source app_icon.sh; app_icon Ghostty`

app_icon() {
  case "$1" in
    # Browsers
    "com.apple.Safari" | Safari)                 echo "" ;;
    Firefox | "org.mozilla.firefox")             echo "" ;;
    Zen | "app.zen-browser.zen")             	 echo "󰺕" ;;
    "com.google.Chrome" | "Google Chrome" | Arc | "company.thebrowser.Browser" | Helium | Terax)       echo "" ;;
    "com.brave.Browser" | Brave*)                echo "" ;;
    "com.microsoft.edgemac" | "Microsoft Edge")  echo "" ;;
    "org.mozilla.firefoxdeveloperedition" | \
    "Firefox Developer Edition")                 echo "" ;;

    # Terminals
    "com.apple.Terminal" | Terminal)             echo "" ;;
    "com.googlecode.iterm2" | iTerm2)            echo "" ;;
    Ghostty | "com.mitchellh.ghostty" | Warp | Wave | "dev.warp.Warp-Stable")           echo "" ;;
    "net.kovidgoyal.kitty" | kitty)              echo "" ;;
    "io.alacritty" | Alacritty)                  echo "" ;;
    "org.wezfurlong.wezterm" | WezTerm)          echo "" ;;

    # Editors / IDE
    Code | "com.microsoft.VSCode" | \
    "com.visualstudio.code" | Cursor | Windsurf | Zed | "dev.zed.Zed" | com.todesktop.*)                     echo "" ;;
    "com.microsoft.VSCodeInsiders" | \
    "Visual Studio Code - Insiders")             echo "" ;;
    "com.jetbrains.intellij" | IntelliJ*)        echo "" ;;
    "com.jetbrains.pycharm" | PyCharm*)          echo "" ;;
    "com.jetbrains.webstorm" | WebStorm*)        echo "" ;;
    "com.sublimetext.4" | "Sublime Text")        echo "" ;;
    "com.apple.dt.Xcode" | Xcode)                echo "" ;;

    # Chat / meetings
    Discord | "com.hnc.Discord")                 echo "" ;;
    "com.tinyspeck.slackmacgap" | Slack)         echo "" ;;
    "us.zoom.xos" | zoom.us | Zoom)              echo "" ;;
    "com.microsoft.teams" | \
    "com.microsoft.teams2" | Microsoft\ Teams)   echo "" ;;
    "com.apple.FaceTime" | FaceTime)             echo "" ;;
    "com.apple.iChat" | Messages | WhatsApp | *WhatsApp*)                echo "" ;;
    "com.apple.mail" | Mail)                     echo "" ;;

    # Music / media
    Spotify | "com.spotify.client")              echo "" ;;
    "com.apple.Music" | Music)                   echo "" ;;
    "com.apple.TV" | TV)                         echo "" ;;
    "com.apple.QuickTimePlayerX" | QuickTime*)   echo "" ;;
    "org.videolan.vlc" | VLC | Stremio | *stremio*)                    echo "" ;;

    # Apple / system
    "com.apple.finder" | Finder | Marta)                 echo "" ;;
    "com.apple.systempreferences" | \
    "com.apple.SystemSettings" | \
    "System Preferences" | "System Settings")    echo "" ;;
    "com.apple.ActivityMonitor" | Activity\ Monitor) echo "" ;;
    "com.apple.Console" | Console)               echo "" ;;
    "com.apple.DiskUtility" | Disk\ Utility)     echo "" ;;
    "com.apple.TimeMachine" | Time\ Machine)     echo "" ;;
    "com.apple.AppStore" | App\ Store)           echo "" ;;
    "com.apple.Preview" | Preview)               echo "" ;;
    "com.apple.Photos" | Photos)                 echo "" ;;
    "com.apple.Calculator" | Calculator)         echo "" ;;
    "com.apple.iCal" | Calendar)                 echo "" ;;
    "com.apple.Notes" | Notes)                   echo "" ;;
    "com.apple.Reminders" | Reminders)           echo "" ;;
    "com.apple.Maps" | Maps)                     echo "" ;;
    "com.apple.Dictionary" | Dictionary)         echo "" ;;
    "com.apple.TextEdit" | TextEdit)             echo "" ;;
    "com.apple.Stickies" | Stickies)             echo "" ;;
    "com.apple.FontBook" | Font\ Book)           echo "" ;;
    "com.apple.Screenshot" | Screenshot)         echo "" ;;
    "com.apple.ImageCapture" | Image\ Capture)   echo "" ;;
    "com.apple.Automator" | Automator)           echo "" ;;
    "com.apple.Shortcuts" | Shortcuts | Raycast)           echo "" ;;
    "com.apple.Home" | Home)                     echo "" ;;
    "com.apple.Books" | Books)                   echo "" ;;
    "com.apple.News" | News)                     echo "" ;;
    "com.apple.Poddcasts" | Podcasts | \
    "com.apple.podcasts")                        echo "" ;;

    # Cloud / notes / productivity
    "com.notion.id" | Notion)                    echo "" ;;
    "com.electron.logseq" | Logseq)              echo "" ;;
    "md.obsidian" | Obsidian)                    echo "" ;;
    "com.todoist.mac.Todoist" | Todoist)         echo "" ;;
    "com.apple.iWork.Pages" | Pages)             echo "" ;;
    "com.apple.iWork.Numbers" | Numbers)         echo "" ;;
    "com.apple.iWork.Keynote" | Keynote)         echo "" ;;
    "com.microsoft.Word" | Microsoft\ Word)      echo "" ;;
    "com.microsoft.Excel" | Microsoft\ Excel)    echo "" ;;
    "com.microsoft.Powerpoint" | Microsoft\ PowerPoint) echo "" ;;

    # Dev tools
    "com.apple.SafariTechnologyPreview" | \
    "Safari Technology Preview")                 echo "" ;;
    "com.postmanlabs.mac" | Postman | Yaak | HTTPie | *yaak* | *httpie*)             echo "" ;;
    "com.docker.docker" | Docker)                echo "" ;;
    "com.github.GitHubClient" | GitHub\ Desktop) echo "" ;;
    "com.tinyspeck.slackmacgap" | Slack)         echo "" ;;
    "com.jgraph.drawio.desktop" | draw.io | Figma | "com.figma.Desktop")       echo "" ;;

    *)
      echo ""
      ;;
  esac
}
