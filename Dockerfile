FROM ubuntu:20.04
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get -y update && apt-get -y install curl
RUN useradd -u 1000 -m webuser

RUN cd /usr/share && \
    curl -O https://julialang-s3.julialang.org/bin/linux/x64/1.8/julia-1.8.0-linux-x86_64.tar.gz && \
    tar xfvz julia-1.8.0-linux-x86_64.tar.gz

RUN ln -s /usr/share/julia-1.8.0/bin/julia /usr/bin/julia
RUN apt-get -y install git emacs-nox

USER webuser
WORKDIR /home/webuser

RUN git clone https://github.com/holzman/CovidCountyDash.jl
WORKDIR /home/webuser/CovidCountyDash.jl

RUN julia --project -e 'using Pkg; Pkg.precompile();'

CMD julia --project bin/main.jl
