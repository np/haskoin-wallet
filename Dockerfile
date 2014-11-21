FROM quay.io/np__/haskoin

MAINTAINER Nicolas Pouillard [https://nicolaspouillard.fr]

ADD     haskoin-wallet.cabal /haskoin-wallet/haskoin-wallet.cabal
WORKDIR /haskoin-wallet
RUN     cabal update && cabal install --dependencies-only --enable-tests
#ADD     . /haskoin-wallet
ADD     Network /haskoin-wallet/Network
ADD     script  /haskoin-wallet/script
ADD     tests   /haskoin-wallet/tests
RUN     cabal install
RUN     cabal test || echo "The tests failed!"
