import FungibleToken from 0xFUNGIBLETOKENADDRESS
import NonFungibleToken from 0xNFTADDRESS

pub contract EternalAuction {

    pub var nextAuctionID: UInt64
    pub var nextBidID: UInt64

    pub resource interface AuctionPublic {
        // Create a bid.
        pub fun createBid(tokens: @FungibleToken.Vault): @BidReference

        // End the auction.
        // Note that an auction can only be ended if conditions are satisfied.
        pub fun end()
    }

    pub resource interface AuctionPrivate {
        // Once the auction has ended, the auction owner may withdraw items that have not
        // been sold.
        pub fun withdrawItems(): @[NonFungibleToken.NFT]

        // Once the auction has ended, the auction owner may withdraw tokens from the
        // winning bids.
        pub fun withdrawWinningBids(): @FungibleToken.Vault?
    }

    pub resource AuctionReference: AuctionPublic, AuctionPrivate {
        pub let auctionID: UInt64

        init(auctionID: UInt64) {
            self.auctionID = auctionID
        }

        pub fun createBid(tokens: @FungibleToken.Vault): @BidReference {
            let auctionState = EternalAuction.borrowAuctionState(id: self.auctionID)
            if !tokens.isInstance(auctionState.tokenType) {
                panic("unexpected token type")
            }

            let amount = tokens.balance
            let bid <- create BidState(auctionID: self.auctionID, tokens: <-tokens)
            let bidID = bid.bidID
            auctionState.addBid(bid: <- bid)

            return <- create BidReference(auctionID: self.auctionID, bidID: bidID, amount: amount)
        }

        pub fun withdrawItems(): @[NonFungibleToken.NFT] {
            let auctionState = EternalAuction.borrowAuctionState(id: self.auctionID)
            return <- auctionState.withdrawUnsoldItems()
        }

        pub fun withdrawWinningBids(): @FungibleToken.Vault? {
            let auctionState = EternalAuction.borrowAuctionState(id: self.auctionID)
            return <- auctionState.withdrawWinningBids()
        }
        
        pub fun end() {
            let auctionState = EternalAuction.borrowAuctionState(id: self.auctionID)
            auctionState.end()
        }
    }

    pub resource interface BidPublic {
        pub let amount: UFix64
    }

    pub resource interface BidPrivate {
        // If the bid has been outbid, the bidder can withdraw the tokens
        pub fun withdrawTokens(): @FungibleToken.Vault

        // Once the auction has ended, if the bid is one of the winning bids, the
        // bidder can withdraw the item that they won.
        pub fun withdrawItem(): @NonFungibleToken.NFT

        // The bidder can end the auction too, as long as the conditions are met.
        // If an auction could only be ended through a AuctionReference, then whoever
        // owns the reference could troll bidders by hiding the reference.  Therefore
        // we allow bidders to end auctions too.
        pub fun endAuction()
    }

    pub resource BidReference: BidPublic, BidPrivate {
        pub let auctionID: UInt64
        pub let bidID: UInt64
        pub let amount: UFix64

        init(auctionID: UInt64, bidID: UInt64, amount: UFix64) {
            self.auctionID = auctionID
            self.bidID = bidID
            self.amount = amount
        }

        pub fun withdrawTokens(): @FungibleToken.Vault {
            let auctionState = EternalAuction.borrowAuctionState(id: self.auctionID)

            let bid <- auctionState.outbiddedBids.remove(key: self.bidID)
                ?? panic("cannot withdraw funds from a bid that hasn't been outbidded")
            let vault <- bid.withdrawTokens()
            destroy bid
            return <- vault
        }

        pub fun withdrawItem(): @NonFungibleToken.NFT {
            let auctionState = EternalAuction.borrowAuctionState(id: self.auctionID)

            var i = 0
            while i < auctionState.bids.length {
                if self.bidID == auctionState.bids[i].bidID {
                    return <- auctionState.bids[i].withdrawItem()
                }
                i = i + 1
            }
            panic("the bid did not win an item")
        }

        pub fun endAuction() {
            let auctionState = EternalAuction.borrowAuctionState(id: self.auctionID)
            auctionState.end()
        }
    }

    pub resource AuctionState {
        pub let auctionID: UInt64
        pub let tokenType: Type
        pub let minBidAmount: UFix64
        pub let minBidIncrement: UFix64
        pub let endTime: UFix64

        pub var ended: Bool

        // The items being sold.
        // Once the auction has ended, this stores the items that were not sold.
        access(contract) var items: @[NonFungibleToken.NFT]

        // The current winning bids
        access(contract) var bids: @[BidState]

        // The bids that were outbidded.
        access(contract) var outbiddedBids: @{UInt64: BidState}

        init(items: @[NonFungibleToken.NFT], tokenType: Type, minBidAmount: UFix64, minBidIncrement: UFix64, endTime: UFix64) {
            self.auctionID = EternalAuction.nextAuctionID
            self.tokenType = tokenType
            self.minBidAmount = minBidAmount
            self.minBidIncrement = minBidIncrement
            self.endTime = endTime
            self.ended = false

            self.items <- items
            self.bids <- []
            self.outbiddedBids <- {}

            EternalAuction.nextAuctionID = EternalAuction.nextAuctionID + (1 as UInt64)
        }

        destroy() {
            destroy self.items
            destroy self.bids
            destroy self.outbiddedBids
        }

        access(contract) fun addBid(bid: @BidState) {
            if bid.amount() < self.minBidAmount {
                panic("bid value is lower than the minimum bid amount")
            }

            // If we already have as many bids as there are 
            if self.bids.length >= self.items.length &&
                (bid.amount() - self.bids[self.bids.length - 1].amount()) < self.minBidIncrement {
                panic("bid value needs to be higher than the last-place bid by at least the minimum increment")
            }

            // Insert the bid at the right position of the ladder
            var i = 0
            while i < self.bids.length {
                if self.bids[i].amount() < bid.amount() {
                    break
                }
                i = i + 1
            }

            if i >= self.items.length {
                panic("bid value too low")
            }

            self.bids.insert(at: i, <-bid)

            // Move the outbidded bids out of the ladder
            while self.bids.length > self.items.length {
                let lastBid <- self.bids.remove(at: self.bids.length - 1)

                let nullBid <- self.outbiddedBids[lastBid.bidID] <- lastBid
                destroy nullBid
            }
        }

        access(contract) fun end() {
            let block = getCurrentBlock()
            if block.timestamp < self.endTime {
                panic("cannot end auction before end time")
            }

            self.ended = true

            // Move the sold items into the winning bids
            var i = 0
            while i < self.bids.length {
                self.bids[i].setItem(item: <- self.items.remove(at: 0))
                i = i + 1
            }
        }

        pub fun withdrawUnsoldItems(): @[NonFungibleToken.NFT] {
            if !self.ended {
                panic("cannot withdraw items before the auction ends")
            }

            let items <- self.items <- []
            return <- items
        }

        pub fun withdrawWinningBids(): @FungibleToken.Vault? {
            if !self.ended {
                panic("cannot withdraw items before the auction ends")
            }

            if self.bids.length == 0 {
                return nil
            }

            let tokens <- self.bids[0].withdrawTokens()

            var i = 1
            while i < self.bids.length {
                let nextTokens <- self.bids[i].withdrawTokens()
                tokens.deposit(from: <- nextTokens)
                i = i + 1
            }
            return <-tokens
        }
    }

    pub resource BidState {
        pub let bidID: UInt64
        pub let auctionID: UInt64

        access(contract) var tokens: @FungibleToken.Vault?
        access(contract) var item: @NonFungibleToken.NFT?

        init(auctionID: UInt64, tokens: @FungibleToken.Vault) {
            self.auctionID = auctionID
            self.bidID = EternalAuction.nextBidID
            self.tokens <- tokens
            self.item <- nil

            EternalAuction.nextBidID = EternalAuction.nextBidID + (1 as UInt64)
        }

        destroy() {
            destroy self.tokens
            destroy self.item
        }

        access(contract) fun setItem(item: @NonFungibleToken.NFT) {
            let nilItem <- self.item <- item 
            destroy nilItem
        }

        access(contract) fun withdrawTokens(): @FungibleToken.Vault {
            let tokens <- self.tokens <- nil
            return <- (tokens ?? panic("the bid has no tokens left"))
        }

        pub fun amount(): UFix64 {
            let balance = self.tokens?.balance ?? 0.0
            return balance
        }

        pub fun withdrawItem(): @NonFungibleToken.NFT {
            let auctionState = EternalAuction.borrowAuctionState(id: self.auctionID)

            if !auctionState.ended {
                panic("cannot withdraw item before the auction ends")
            }

            let item <- self.item <- nil
            return <- item!
        }
    }

    pub resource interface AuctionCollectionPublic {
        pub fun createAuction(items: @[NonFungibleToken.NFT], tokenType: Type, minBidAmount: UFix64, minBidIncrement: UFix64, endTime: UFix64): @AuctionReference
    }

    pub resource AuctionCollection: AuctionCollectionPublic {
        pub var auctions: @{UInt64: AuctionState}

        init() {
            self.auctions <- {}
        }

        pub fun borrowAuctionState(id: UInt64): &AuctionState {
            if self.auctions[id] != nil {
                return &self.auctions[id] as auth &AuctionState
            }
            panic("cannot find auction state with given ID")
        }

        pub fun createAuction(items: @[NonFungibleToken.NFT], tokenType: Type, minBidAmount: UFix64, minBidIncrement: UFix64, endTime: UFix64): @AuctionReference {
            let state <- create AuctionState(items: <-items, tokenType: tokenType, minBidAmount: minBidAmount, minBidIncrement: minBidIncrement, endTime: endTime)
            let auctionID = state.auctionID

            let nullState <- self.auctions[state.auctionID] <- state
            destroy nullState

            return <- create AuctionReference(auctionID: auctionID)
        }

        destroy() {
            destroy self.auctions
        }
    }

    access(contract) fun borrowAuctionState(id: UInt64): &AuctionState {
        let collectionRef =
            self.account.borrow<&AuctionCollection>(from: /storage/EternalAuctionCollection)
            ?? panic("cannot find auction with given ID")
        return collectionRef.borrowAuctionState(id: id)
    }

    // Public interface for creating an auction, specifying: 
    // - The items to be sold
    // - The type of fungible tokens to sell for
    // - The minimum bid amount
    // - The minimum bid increment
    // - The (minimum) end time of the auction
    pub fun createAuction(items: @[NonFungibleToken.NFT], tokenType: Type, minBidAmount: UFix64, minBidIncrement: UFix64, endTime: UFix64): @AuctionReference {
        let collectionRef =
            self.account.borrow<&{AuctionCollectionPublic}>(from: /storage/EternalAuctionCollection)
            ?? panic("cannot find auction collection")
        return <- collectionRef.createAuction(items: <-items, tokenType: tokenType, minBidAmount: minBidAmount, minBidIncrement: minBidIncrement, endTime: endTime)
    }

    init() {
        self.nextAuctionID = 1
        self.nextBidID = 1

        self.account.save<@AuctionCollection>(<- create AuctionCollection(), to: /storage/EternalAuctionCollection)
    }

}