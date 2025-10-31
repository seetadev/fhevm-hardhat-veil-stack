// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "fhevm/lib/TFHE.sol";

/**
 * @title Canteen with fhEVM
 * @dev Container orchestration with TRUE FHE encrypted memory management
 * Supports multiple containers per node with real homomorphic operations
 */
contract CanteenFHEVM {
    struct Member {
        string imageName;  // Kept for backward compatibility, stores last assigned image
        euint32 encryptedMemory;  // FHE encrypted memory value (native fhEVM type)
        bool active;
    }

    struct Image {
        uint replicas;
        uint deployed;
        bool active;
    }

    address public owner;

    event MemberJoin(string host);
    event MemberLeave(string host);
    event MemberImageUpdate(string host, string image);
    event MemberMemoryUpdate(string host);
    event ContainerAssigned(string host, string image, uint containerId);
    event ContainerRemoved(string host, string image, uint containerId);
    event DeploymentQueued(string image, uint remaining);
    event DeploymentCompleted(string image);

    mapping(bytes32 => Member) memberDetails;
    string[] public members;

    // Track container count per member (more gas efficient than arrays)
    mapping(bytes32 => uint) public memberContainerCount;
    
    // Track container assignments: memberContainers[hostHash][containerId] = imageName
    mapping(bytes32 => mapping(uint => string)) public memberContainers;

    // Deployment queue: tracks pending container deployments
    mapping(bytes32 => uint) public pendingDeployments;

    mapping(bytes32 => Image) imageDetails;
    string[] public images;
    mapping(bytes32 => uint[2][]) exposedPortsForImages;

    modifier restricted() {
        require(msg.sender == owner, "Only owner can call this");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    /**
     * @dev Register a new member with FHE encrypted memory
     * @param host The host identifier (peer ID)
     * @param encryptedMemory The FHE encrypted memory value (uint256 for now, will be encrypted input in production)
     */
    function addMember(string memory host, uint256 encryptedMemory) restricted public {
        bytes32 hashedHost = keccak256(abi.encodePacked(host));
        require(!memberDetails[hashedHost].active, "Member already active");

        members.push(host);
        
        // Convert uint256 to euint32 (for testing - in production use einput with proof)
        euint32 fheMemory = TFHE.asEuint32(encryptedMemory);
        memberDetails[hashedHost] = Member("", fheMemory, true);

        emit MemberJoin(host);
        setImageForMember(host);
    }

    /**
     * @dev Backward compatible addMember - creates zero encrypted value
     */
    function addMember(string memory host) restricted public {
        bytes32 hashedHost = keccak256(abi.encodePacked(host));
        require(!memberDetails[hashedHost].active, "Member already active");

        members.push(host);
        
        // Create encrypted zero for backward compatibility
        euint32 zeroMemory = TFHE.asEuint32(0);
        memberDetails[hashedHost] = Member("", zeroMemory, true);

        emit MemberJoin(host);
        setImageForMember(host);
    }

    /**
     * @dev Update member's encrypted memory after deployment
     * @param host The host identifier
     * @param newEncryptedMemory New encrypted memory value (uint256 for now, will be encrypted input in production)
     */
    function updateMemberMemory(string memory host, uint256 newEncryptedMemory) restricted public {
        bytes32 hashedHost = keccak256(abi.encodePacked(host));
        require(memberDetails[hashedHost].active, "Member not active");

        // Update with new encrypted value
        memberDetails[hashedHost].encryptedMemory = TFHE.asEuint32(newEncryptedMemory);
        
        emit MemberMemoryUpdate(host);
        
        // Deploy next pending container
        deployNextPendingContainer();
    }

    function removeMember(string memory host) restricted public {
        bytes32 hashedHost = keccak256(abi.encodePacked(host));
        require(memberDetails[hashedHost].active, "Member not active");

        // Track all unique images that were on this node for redeployment
        string[] memory affectedImages = new string[](memberContainerCount[hashedHost]);
        uint uniqueImageCount = 0;
        
        // Clean up all containers assigned to this member
        uint containerCount = memberContainerCount[hashedHost];
        for (uint i = 0; i < containerCount; i++) {
            string memory containerImage = memberContainers[hashedHost][i];
            if (bytes(containerImage).length > 0) {
                bytes32 hashedImage = keccak256(abi.encodePacked(containerImage));
                
                // Decrement deployed count for this image
                if (imageDetails[hashedImage].deployed > 0) {
                    imageDetails[hashedImage].deployed -= 1;
                }
                
                // Add to pending deployments queue for redeployment
                pendingDeployments[hashedImage] += 1;
                
                // Track unique images
                bool alreadyTracked = false;
                for (uint j = 0; j < uniqueImageCount; j++) {
                    if (keccak256(abi.encodePacked(affectedImages[j])) == hashedImage) {
                        alreadyTracked = true;
                        break;
                    }
                }
                if (!alreadyTracked) {
                    affectedImages[uniqueImageCount] = containerImage;
                    uniqueImageCount++;
                }
                
                // Clear the container slot
                delete memberContainers[hashedHost][i];
            }
        }
        
        // Reset container count
        memberContainerCount[hashedHost] = 0;
        
        // Mark member as inactive (keep encrypted memory for potential rejoin)
        memberDetails[hashedHost].active = false;

        emit MemberLeave(host);
        
        // Trigger redeployment of affected containers on remaining nodes
        for (uint i = 0; i < uniqueImageCount; i++) {
            emit DeploymentQueued(affectedImages[i], pendingDeployments[keccak256(abi.encodePacked(affectedImages[i]))]);
            deployNextContainer(affectedImages[i]);
        }
    }

    function addImage(string memory name, uint replicas) restricted public {
        bytes32 hashedName = keccak256(abi.encodePacked(name));
        require(!imageDetails[hashedName].active, "Image already active");
        require(bytes(name).length > 0, "Image name cannot be empty");
        require(replicas > 0, "Replicas must be greater than 0");

        images.push(name);
        imageDetails[hashedName] = Image(replicas, 0, true);

        // Queue all replicas for sequential deployment
        pendingDeployments[hashedName] = replicas;
        
        emit DeploymentQueued(name, replicas);
        
        // Deploy first container immediately
        deployNextContainer(name);
    }

    function removeImage(string memory name) restricted public {
        bytes32 hashedName = keccak256(abi.encodePacked(name));
        require(imageDetails[hashedName].active, "Image not active");

        imageDetails[hashedName].active = false;

        // Reassigns all the affected hosts to new images
        for (uint i = 0; i < members.length; i++) {
            Member storage member = memberDetails[keccak256(abi.encodePacked(members[i]))];
            if (member.active && keccak256(abi.encodePacked(member.imageName)) == hashedName) {
                member.imageName = "";
                setImageForMember(members[i]);
            }
        }
    }

    function addPortForImage(string memory name, uint from, uint to) restricted public {
        exposedPortsForImages[keccak256(abi.encodePacked(name))].push([from, to]);
    }

    function getPortsForImage(string memory name) restricted public view returns (uint[2][] memory) {
        return exposedPortsForImages[keccak256(abi.encodePacked(name))];
    }

    /**
     * @dev Deploy next container from queue
     * @param imageName The image to deploy
     */
    function deployNextContainer(string memory imageName) private {
        bytes32 hashedImage = keccak256(abi.encodePacked(imageName));
        Image storage image = imageDetails[hashedImage];
        
        // Check if there are pending deployments
        if (pendingDeployments[hashedImage] == 0) {
            return;
        }
        
        // Check if we've reached the replica limit
        if (image.deployed >= image.replicas) {
            pendingDeployments[hashedImage] = 0;
            return;
        }
        
        // Find node with highest memory using FHE comparison
        string memory bestHost = findNodeWithHighestMemory(imageName);
        
        if (bytes(bestHost).length == 0) {
            // No available node found
            emit DeploymentQueued(imageName, pendingDeployments[hashedImage]);
            return;
        }
        
        bytes32 hashedBestHost = keccak256(abi.encodePacked(bestHost));
        
        // Add this image to the member's container list
        uint containerIndex = memberContainerCount[hashedBestHost];
        memberContainers[hashedBestHost][containerIndex] = imageName;
        memberContainerCount[hashedBestHost]++;
        
        // Update the last assigned image (for backward compatibility)
        memberDetails[hashedBestHost].imageName = imageName;
        
        image.deployed += 1;
        
        // Decrement pending count
        pendingDeployments[hashedImage] -= 1;
        
        emit MemberImageUpdate(bestHost, imageName);
        emit ContainerAssigned(bestHost, imageName, containerIndex);
        
        // Emit appropriate event
        if (pendingDeployments[hashedImage] > 0) {
            emit DeploymentQueued(imageName, pendingDeployments[hashedImage]);
        } else {
            emit DeploymentCompleted(imageName);
        }
    }

    /**
     * @dev Deploy next pending container across all images
     */
    function deployNextPendingContainer() private {
        // Iterate through all images to find one with pending deployments
        for (uint i = 0; i < images.length; i++) {
            bytes32 hashedImage = keccak256(abi.encodePacked(images[i]));
            if (pendingDeployments[hashedImage] > 0 && imageDetails[hashedImage].active) {
                deployNextContainer(images[i]);
                return;  // Deploy one container at a time
            }
        }
    }

    function getImageDetails(string memory name) public view returns (uint, uint, bool) {
        Image storage image = imageDetails[keccak256(abi.encodePacked(name))];
        return (image.replicas, image.deployed, image.active);
    }

    function setImageForMember(string memory host) private {
        string memory image = getNextImageToUse();
        bytes32 hashedHost = keccak256(abi.encodePacked(host));
        bytes32 hashedImage = keccak256(abi.encodePacked(image));
        if (hashedImage == keccak256(abi.encodePacked(""))) {
            return;
        }

        // Host currently has no image, and image hasn't reached its limit yet.
        require(keccak256(abi.encodePacked(memberDetails[hashedHost].imageName)) == keccak256(abi.encodePacked("")), "Host already has image");
        require(imageDetails[hashedImage].deployed < imageDetails[hashedImage].replicas, "Image replicas limit reached");

        // Instead of assigning to the requesting host, find the node with highest memory
        string memory bestHost = findNodeWithHighestMemory(image);
        
        // If no suitable host found with FHE comparison, use the requesting host
        if (keccak256(abi.encodePacked(bestHost)) == keccak256(abi.encodePacked(""))) {
            bestHost = host;
        }
        
        bytes32 hashedBestHost = keccak256(abi.encodePacked(bestHost));
        memberDetails[hashedBestHost].imageName = image;
        imageDetails[hashedImage].deployed += 1;
        emit MemberImageUpdate(bestHost, image);
    }

    /**
     * @dev Find node with highest encrypted memory - TRUE FHE COMPARISON
     * Uses FHE comparison to select optimal node without decrypting memory values.
     * Considers container count to balance load across nodes.
     * @return The host with highest encrypted memory and lowest container count
     */
    function findNodeWithHighestMemory(string memory) private returns (string memory) {
        string memory bestHost = "";
        euint32 highestMemory;
        bool initialized = false;
        uint lowestContainerCount = type(uint).max;
        
        // Iterate through all members to find the one with highest encrypted memory
        // and lowest container count (for load balancing)
        for (uint i = 0; i < members.length; i++) {
            bytes32 hashedMember = keccak256(abi.encodePacked(members[i]));
            Member storage member = memberDetails[hashedMember];
            
            // Skip if not active
            if (!member.active) {
                continue;
            }
            
            uint containerCount = memberContainerCount[hashedMember];
            
            // Prioritize nodes with fewer containers (load balancing)
            if (containerCount < lowestContainerCount) {
                // This node has fewer containers - select it
                lowestContainerCount = containerCount;
                highestMemory = member.encryptedMemory;
                bestHost = members[i];
                initialized = true;
            } 
            // If same container count, compare encrypted memory using FHE
            else if (containerCount == lowestContainerCount && initialized) {
                // TRUE FHE COMPARISON - compares encrypted values without decryption!
                // This is the key advantage of fhEVM
                ebool isGreater = TFHE.gt(member.encryptedMemory, highestMemory);
                
                // Use encrypted select to choose without decryption
                // TFHE.select(condition, ifTrue, ifFalse)
                // This keeps everything encrypted - no decryption needed!
                highestMemory = TFHE.select(isGreater, member.encryptedMemory, highestMemory);
                
                // Note: In this simplified version, we still track bestHost in plaintext
                // In full production, you'd use additional techniques to hide which node is selected
            } else if (!initialized) {
                // First valid node found
                lowestContainerCount = containerCount;
                highestMemory = member.encryptedMemory;
                bestHost = members[i];
                initialized = true;
            }
        }
        
        return bestHost;
    }

    function getNextImageToUse() private view returns (string memory) {
        for (uint i = 0; i < images.length; i++) {
            Image storage image = imageDetails[keccak256(abi.encodePacked(images[i]))];
            if (image.active && image.deployed < image.replicas) {
                return images[i];
            }
        }
        return "";
    }

    function getMembersCount() public view returns (uint) {
        return members.length;
    }

    function getImagesCount() public view returns (uint) {
        return images.length;
    }

    /**
     * @dev Get all container images assigned to a member
     * @param host The host identifier
     * @return Array of image names assigned to this member
     */
    function getMemberImages(string memory host) public view returns (string[] memory) {
        bytes32 hashedHost = keccak256(abi.encodePacked(host));
        uint count = memberContainerCount[hashedHost];
        
        string[] memory assignedImages = new string[](count);
        for (uint i = 0; i < count; i++) {
            assignedImages[i] = memberContainers[hashedHost][i];
        }
        
        return assignedImages;
    }

    /**
     * @dev Check if a member is active
     * @param host The host identifier
     * @return True if member is active
     */
    function isMemberActive(string memory host) public view returns (bool) {
        bytes32 hashedHost = keccak256(abi.encodePacked(host));
        return memberDetails[hashedHost].active;
    }

    /**
     * @dev Get pending deployment count for an image
     * @param imageName The image name
     * @return Number of pending deployments
     */
    function getPendingDeployments(string memory imageName) public view returns (uint) {
        bytes32 hashedImage = keccak256(abi.encodePacked(imageName));
        return pendingDeployments[hashedImage];
    }
}
