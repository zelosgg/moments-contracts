// The EternalAuction contract conducts English auctions for arbitrary NFTs.
// The only difference with a normal English auction is that we may be auctioning
// off multiple NFTs in the same auction.  The NFTs would be ordered, and the
// top bidder gets the first NFT, the second top bidder gets the second NFT,
// so on and so forth.
//
// Anyone can create an auction resource.  The contract itself doesn't store or
// list the auctions created -- it's up to another listing site/service to list
// the auctions.
// 
// Auctions are settled lazily -- that is, when the time is up, it's not required
// for anyone to send a transaction to settle the auction.  The contract will simply
// use the timestamp to decide whether the auction has ended and handle transactions
// accordingly.

import FungibleToken from 0xFUNGIBLETOKENADDRESS
import NonFungibleToken from 0xNFTADDRESS

pub contract EternalAuction {

    access(self) var auctionStates: @{UInt64: AuctionState}
    access(self) var nextAuctionID: UInt64
    access(self) var nextBidID: UInt64

    init() {
        self.nextAuctionID = 0
        self.nextBidID = 0
    }

    pub fun startAuction(items: @[NonFungibleToken.NFT]): @Auction {
        let auctionID = self.nextAuctionID
        self.nextAuctionID = self.nextAuctionID + 1

        auctionStates[auctionID] <- create AuctionState(auctionID, items: <-items)
        return create Auction(auctionID, &self.auctionStates[auctionID])
    }

    pub fun addBid(auctionID: uint64, tokens: @FungibleToken.Vault, refundReceiver: Capability<&{FungibleToken.Receiver}>): @Bid {
        let bidID = self.nextBidID
        self.nextBidID = self.nextBidID + 1

        let state = &auctionStates[auctionID]

        // Maintain a sorted list of bids
        let bidsCount = state.bids.length
        var i = 0
        while i < bidsCount {
            if bid.vault.balance < tokens.balance {
                break
            }
            i = i + 1
        }
        state.bids.insert(at: i, create BidState(bidID, <- tokens, refundReceiver))

        // If we now have more bidders than items, we refund the outbidded people
        while state.bids.length > state.items.length {
           let lastBid <- state.bids.remove(at: state.bids.length)
           lastBid.refund()
           destroy lastBid
        }

        return <- create Bid(bidID, state)
    }

    access(self) resource BidState {
        pub var id: UInt64
        pub var vault: @FungibleToken.Vault
        pub var refundReceiver: Capability<&{FungibleToken.Receiver}>

        pub fun refund() {
            self.refundReceiver
            if let vaultRef = refundReceiver.borrow() {
                let bidVaultRef = &self.bidVault as &FungibleToken.Vault
                vaultRef.deposit(from: <-vault.withdraw(amount: bidVaultRef.balance))
                return
            }

            // It is possible that the receiver is no longer valid, e.g. because the
            // user moved the receiver vault to another storage location.
            // In this case, it's important that we don't fail, because otherwise an
            // attacker can intentionally remove their receiver in order to "jam"
            // the auction.
        }
    }

    access(self) resource AuctionState {
        pub var id: UInt64
        pub var ended: Bool

        pub var items: @[NonFungibleToken.NFT]

        // A sorted array of bids, ordered by their vault balances (from higher to lower)
        pub var bids: @[BidState]

        // Once an auction ends, this variable stores the NFTs that are actually sold,
        // mapping from the bid ID.
        // It's possible for NFTs to be partially sold because there could be less
        // bidders than NFTs.
        pub var itemsSold: @{UInt64: NonFungibleToken.NFT}

        pub var itemsNotSold: @[NonFungibleToken.NFT]

        pub fun end() {

            if self.ended {
                return
            }

            let itemCount = self.items.length

            var i = 0
            while i < bids.length {
                self.itemsSold[bids[i].id] <- items.remove(at: 0)
                i = i + 1
            }

            // whatever remains are the items that haven't been sold
            itemsNotSold <- items

            self.ended = true

        }

        init(auctionID: UInt64, items: @[NonFungibleToken.NFT]) {
            self.id = auctionID
            self.items = items
            self.tokens = {}

            self.winningBidTokens = []
            self.itemsSold = []
        }
    }

    pub resource Auction {
        pub var id: UInt64
        access(self) state: &AuctionState

        // End the auction.  Once an auction has ended, winning bidders can claim the
        // NFTs and auction owner can claim the bids.
        pub fun end() {
            self.state.end()
        }

        // If the auction has ended, the auction owner can claim the FTs from the winners.
        pub fun claimBids(): @[FungibleToken.Vault] {
            if !self.state.ended {
                panic("The auction has not ended.")
            }

            let vaults = []
            while bids.length > 0 {
                let bid <- self.state.bids.remove(at: 0)
                vaults.append(<- bid.vault)
            }

            return <- vaults
        }

        init(id: UInt64, state: &AuctionState) {
            self.id = id
            self.state = state
        }
    }

    pub resource Bid {
        pub var id: UInt64

        access(self) state: &AuctionState

        // If the auction 
        pub fun withdraw(): @FungibleToken.Vault {
        }

        // If the auction has ended and the bid owner has won, they can claim the item.
        pub fun claimItem(): @NonFungibleToken.NFT {
            if !self.state.ended {
                panic("The auction has not ended.")
            }

            if self.state.itemsSold[self.id] == nil {
                panic("The bid is not valid.")
            }

            return <- self.state.itemsSold.remove(key: self.id)
        }

        // It's important that bidders can also trigger the ending of an auction,
        // because otherwise the auction owner can troll by refusing to end the
        // auction, resulting in bidders being unable to neither getting the NFTs
        // nor getting their tokens back.
        pub fun end() {
            self.state.end()
        }
    }


}
