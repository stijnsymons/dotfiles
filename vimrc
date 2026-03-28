set nocompatible              " be iMproved, required
filetype off                  " required

" vim-plug -------------------------------------------------------------------
call plug#begin('~/.vim/plugged')
Plug 'ayu-theme/ayu-vim'
" Plug '/usr/local/opt/fzf' | Plug 'junegunn/fzf.vim'                 " navigation
Plug 'itchyny/lightline.vim'                    " lightweight statusline
"Plug 'tpope/vim-fugitive'                       " git stuff
Plug 'airblade/vim-gitgutter'                   " indicate changes in leftbar based on git
Plug 'bronson/vim-trailing-whitespace'          " whitespace police
Plug 'nathanaelkane/vim-indent-guides'          " Indent Guides is a plugin for visually displaying indent levels
Plug 'tpope/vim-surround'                       " surround stuff around stuff
" Plug 'scrooloose/nerdtree'                      " sidebar navigation
Plug 'tpope/vim-commentary'                     " easy comments
" Plug 'sotte/presenting.vim'                     " build evernote style quick presentations
Plug 'yukunlin/auto-pairs'                      " autoclose parens
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
"let ayucolor="light"  " for light version of theme
let ayucolor="mirage" " for mirage version of theme
"let ayucolor="dark"   " for dark version of theme
" colorscheme ayu

" Plugins --------------------------------------------------------------------

" tab for autocomplete
inoremap <expr><tab> pumvisible() ? "\<c-n>" : "\<tab>"

" fzf
" set rtp+=/usr/local/opt/fzf
"
" let g:fzf_action = {
"   \ 'ctrl-t': 'tab split',
"   \ 'ctrl-x': 'split',
"   \ 'ctrl-v': 'vsplit' }

" lightline
let g:lightline = {
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
" nnoremap <C-p> :Files<CR>
" nnoremap <C-b> :Buffers<CR>
" nnoremap <C-r> :Ag<CR>

" Nerdtree
" nnoremap <C-e> :NERDTreeToggle<CR>
