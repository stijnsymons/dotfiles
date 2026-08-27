set nocompatible              " be iMproved, required
filetype off                  " required

" vim-plug -------------------------------------------------------------------
" Bootstrap vim-plug itself if this machine has never had it, so a fresh clone
" of the dotfiles needs nothing but vim and curl to come up working.
let s:plug_path = expand('~/.vim/autoload/plug.vim')
if empty(glob(s:plug_path))
  silent execute '!curl -fLo ' . shellescape(s:plug_path) . ' --create-dirs https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim'
  autocmd VimEnter * PlugInstall --sync | source $MYVIMRC
endif

call plug#begin('~/.vim/plugged')
Plug 'catppuccin/vim', { 'as': 'catppuccin' }   " theme (latte/frappe/macchiato/mocha)
Plug '/opt/homebrew/opt/fzf' | Plug 'junegunn/fzf.vim'                " navigation
Plug 'itchyny/lightline.vim'                    " lightweight statusline
"Plug 'tpope/vim-fugitive'                       " git stuff
Plug 'airblade/vim-gitgutter'                   " indicate changes in leftbar based on git
Plug 'bronson/vim-trailing-whitespace'          " whitespace police
Plug 'nathanaelkane/vim-indent-guides'          " Indent Guides is a plugin for visually displaying indent levels
Plug 'tpope/vim-surround'                       " surround stuff around stuff
Plug 'tpope/vim-commentary'                     " easy comments
Plug 'sotte/presenting.vim'                      " build evernote style quick presentations
Plug 'honza/vim-snippets'                       " snippets
call plug#end()

" Basic Options --------------------------------------------------------------
let mapleader=";"

set clipboard=unnamed                           " set yank register to osx clipboard
set ignorecase                                  " Case insensitive search
set expandtab                                   " spaces, not tabs
set shiftwidth=4
set tabstop=4
set softtabstop=4
"set colorcolumn=80                              " Row length
set nu                                          " set numbers, to get the current line
set relativenumber                              " requiredlative row numbers
set showcmd                                     " Show typed commands
set incsearch                                   " incremental search
set hlsearch                                    " highlight search matches
set wildmode=longest,list,full                  " Auto complete bash mode
set wildmenu                                    " Auto complete bash mode
set backspace=indent,eol,start                  " backspace
set fillchars=vert:\                            " nicer divider, no char inside
set mouse=a                                     " mouse support in terminal
set wildignore+=*/tmp/*,*/node_modules/*,*/bower_components/*,*.o,*.png,*.jpg,*.zip,*.tar,*.pyc,*.min.js,.sass-cache/*,./vendor/*,./app/cache/*,./app/logs/*
set splitbelow                                  " Splits show up below by default
set splitright                                  " Splits go to the right by default

" Theme ----------------------------------------------------------------------
set termguicolors     " enable true colors support

" Follow the macOS appearance: Catppuccin Latte in light, Macchiato in dark.
" Re-checked on FocusGained, so flipping appearance recolours an already-open
" vim the moment you click back into it, rather than waiting on the launchd
" poll. `defaults read` costs ~10ms and only runs on focus.
" silent! on the colorscheme so a fresh machine, before PlugInstall has run,
" still opens instead of dying with E185: Cannot find color scheme.
function! s:SyncAppearance(...) abort
  let l:dark = has('macunix')
        \ && system('defaults read -g AppleInterfaceStyle 2>/dev/null') =~? 'dark'
  let l:bg = l:dark ? 'dark' : 'light'
  let l:cs = l:dark ? 'catppuccin_macchiato' : 'catppuccin_latte'

  if get(g:, 'colors_name', '') !=# l:cs || &background !=# l:bg
    let &background = l:bg
    silent! execute 'colorscheme' l:cs
  endif

  " lightline caches its palette, so it needs an explicit rebuild
  if exists('g:lightline') && get(g:lightline, 'colorscheme', '') !=# l:cs
    let g:lightline.colorscheme = l:cs
    if exists('*lightline#init')
      call lightline#init()
      call lightline#colorscheme()
      call lightline#update()
    endif
  endif
endfunction

augroup AppearanceSync
  autocmd!
  autocmd VimEnter,FocusGained * call s:SyncAppearance()
augroup END

call s:SyncAppearance()

" Plugins --------------------------------------------------------------------

" tab for autocomplete
inoremap <expr><tab> pumvisible() ? "\<c-n>" : "\<tab>"

" fzf
set rtp+=/opt/homebrew/opt/fzf

let g:fzf_action = {
  \ 'ctrl-t': 'tab split',
  \ 'ctrl-x': 'split',
  \ 'ctrl-v': 'vsplit' }

" lightline
let g:lightline = {
      \ 'colorscheme': 'catppuccin_latte',
      \ 'active': {
      \   'left': [ [ 'mode', 'paste' ],
      \             [ 'filename', 'modified' ] ,
      \             ['buffers'] ]
      \ },
      \ 'component_function': {
      \   'buffers': 'LightLineBuffers',
      \   'modified': 'LightLineModified'
      \ }
      \ }

function! LightLineModified()
  if &filetype == "help"
    return ""
  elseif &modified
    return "+"
  elseif &modifiable
    return ""
  else
    return ""
  endif
endfunction

function! LightLineBuffers()
  return len(filter(range(1, bufnr('$')), 'buflisted(v:val)')) + '/' + bufnr('%')
endfunction

" Vim Indent Guide
" let g:indent_guides_auto_colors = 0
" hi IndentGuidesOdd  ctermbg=black
" hi IndentGuidesEven ctermbg=darkgrey

" Mapping --------------------------------------------------------------------

" make jk move down screenwise, not linewise
nmap j gj
nmap k gk

" Disable man page
noremap K <nop>

" disable Ex mode
nnoremap Q <nop>

" Navigation -----------------------------------------------------------------

" cycle buffers with ,
nnoremap , :bnext<CR>
nnoremap <C-,> :bprevious<CR>

" Make navigating around splits easier
nnoremap <C-j> <C-w>j
nnoremap <C-k> <C-w>k
nnoremap <C-h> <C-w>h
nnoremap <C-l> <C-w>l
if has('nvim')
  " We have to do this to fix a bug with Neovim on OS X where C-h
  " is sent as backspace for some reason.
  nnoremap <BS> <C-W>h
endif

" fzf
nnoremap <C-p> :Files<CR>
nnoremap <C-b> :Buffers<CR>
nnoremap <C-r> :Ag<CR>
