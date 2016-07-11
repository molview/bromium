// Copyright (c) 2016, Herman Bergwerf. All rights reserved.
// Use of this source code is governed by an AGPL-3.0-style license
// that can be found in the LICENSE file.

part of bromium.structs;

/// All information during a simulation. All data is final. All underlying
/// dynamic data is backed by the [buffer].
class Simulation {
  /// Buffer max size (300MB)
  static const maxBufferSize = 100000000;

  /// Buffer particles cap
  static const particlesCap = 10000;

  /// Buffer membranes cap
  static const membranesCapBytes = 120;

  /// Byte buffer for data that must be continously streamed to the frontend.
  /// This contains 3D render input and simulation state information this is
  /// displayed in the user interface. This buffer can be parsed using
  /// [RenderBuffer].
  ByteBuffer buffer;

  /// Simulation dimensions
  final SimulationHeader header;

  /// Store particles offset in the buffer for convenience. This value can
  /// be calculated from the [header].
  int particlesOffset = 0;

  /// Particle types
  final List<ParticleType> particleTypes;

  /// Bind reactions
  final List<BindReaction> bindReactions;

  /// Unbind reactions
  final List<UnbindReaction> unbindReactions;

  /// Particles
  final List<Particle> particles;

  /// Membranes
  final List<Membrane> membranes;

  /// Load simulation from loose data.
  Simulation(this.particleTypes, List<BindReaction> bindReactions,
      List<UnbindReaction> unbindReactions)
      : header =
            new SimulationHeader(bindReactions.length, unbindReactions.length),
        bindReactions = bindReactions,
        unbindReactions = unbindReactions,
        particles = [],
        membranes = [] {
    // Compute particles offset.
    particlesOffset = SimulationHeader.byteCount +
        Reaction.byteCount *
            (header.bindReactionCount + header.unbindReactionCount);

    // Transfer all data to a single byte buffer.
    transfer(0, 0);
  }

  /// Add new particles by randomly generating [n] positions within [domain].
  void addRandomParticles(int type, Domain domain, int n) {
    _rescaleBuffer(n, 0);

    // Generate particles.
    for (; n > 0; n--) {
      _addParticle(new Particle(type, domain.computeRandomPoint(),
          particleTypes[type].displayColor, particleTypes[type].displayRadius));
    }
  }

  /// Unsafe add particle to buffer.
  void _addParticle(Particle particle) {
    particle.transfer(
        buffer, particlesOffset + Particle.byteCount * particles.length);
    particles.add(particle);
  }

  /// Add a membrane to the buffer.
  void addMembrane(Membrane membrane) {
    _rescaleBuffer(0, membrane.sizeInBytes);
    membrane.transfer(buffer, header.membranesOffset + allMembraneBytes);
    membranes.add(membrane);
  }

  /// Remove particle
  void removeParticle(int p) {
    /// Swap particle p with the last particle unless p is the last particle.
    if (p < particles.length - 1) {
      /// Transfer the last particle to the byte buffer spot of particle p.
      particles.last.transfer(buffer, particlesOffset + p * Particle.byteCount);

      /// Replace particle p with the last particle.
      particles[p] = particles.removeLast();
    } else {
      particles.removeLast();
    }
  }

  /// Bind two particles.
  void bindParticles(int a, int b, int type) {
    /// Remove particle b.
    removeParticle(b);

    /// Set particle a to the new type.
    particles[a].type = type;
    particles[a].setColor(particleTypes[type].displayColor);
    particles[a].setRadius(particleTypes[type].displayRadius);
  }

  /// Apply multiple bind reactions (takes care of index displacement).
  void applyBindReactions(List<Tuple3<int, int, int>> rxns) {
    // In all reactions set item1 to the smallest of {item1, item2}.
    for (var i = 0; i < rxns.length; i++) {
      if (rxns[i].item1 > rxns[i].item2) {
        rxns[i] = new Tuple3<int, int, int>(
            rxns[i].item2, rxns[i].item1, rxns[i].item3);
      }
    }

    // Sort reactions in descending order using item2.
    rxns.sort((Tuple3<int, int, int> a, Tuple3<int, int, int> b) =>
        b.item2 - a.item2);

    // Apply reactions
    for (var rxn in rxns) {
      bindParticles(rxn.item1, rxn.item2, rxn.item3);
    }
  }

  /// Unbind particle into products
  void unbindParticle(int p, List<int> products) {
    /// If products.isNotEmpty, particle p can be replaced with products.first.
    if (products.isNotEmpty) {
      // Add first product.
      final type = products.first;
      particles[p].type = type;
      particles[p].setColor(particleTypes[type].displayColor);
      particles[p].setRadius(particleTypes[type].displayRadius);

      // Add other reaction products.
      _rescaleBuffer(products.length - 1, 0);
      for (var i = 1; i < products.length; i++) {
        final type = products[i];
        _addParticle(new Particle(
            type,
            particles[p].position,
            particleTypes[type].displayColor,
            particleTypes[type].displayRadius));
      }
    } else {
      /// Remove particle p.
      removeParticle(p);
    }
  }

  /// Compute bounding box that encloses all particles.
  Aabb3 particlesBoundingBox() {
    var _min = particles[0].position.clone();
    var _max = particles[0].position.clone();

    for (var p = 1; p < particles.length; p++) {
      Vector3.min(_min, particles[p].position, _min);
      Vector3.max(_max, particles[p].position, _max);
    }

    return new Aabb3.minMax(_min, _max);
  }

  /// Transfer all dynamic data to a new buffer. This method is primarily used
  /// to resize the byte buffer.
  void transfer(int addParticles, int addMembraneBytes) {
    /// Buffer layout:
    /// - header variables
    ///   * number of bind reactions
    ///   * number of unbind reactions
    ///   * number of particles
    ///   * membrane buffer offset (due to particles cap)
    ///   * number of membranes
    /// - bind reaction probabilities
    /// - unbind reaction probabilities
    /// - particles + cap
    /// - membranes + cap

    // Compute new buffer size.
    var membranesOffset = SimulationHeader.byteCount +
        Reaction.byteCount * (bindReactions.length + unbindReactions.length) +
        Particle.byteCount * (particles.length + addParticles + particlesCap);

    var bufferSize = membranesOffset +
        allMembraneBytes +
        addMembraneBytes +
        membranesCapBytes;

    // Create new buffer.
    var newBuffer = new ByteData(bufferSize).buffer;

    // Transfer header.
    var offset = header.transfer(newBuffer, 0);
    header.membranesOffset = membranesOffset;

    // Transfer reactions and particles.
    for (var bindReaction in bindReactions) {
      offset = bindReaction.transfer(newBuffer, offset);
    }
    for (var unbindReaction in unbindReactions) {
      offset = unbindReaction.transfer(newBuffer, offset);
    }
    for (var particle in particles) {
      offset = particle.transfer(newBuffer, offset);
    }

    // Skip particles cap and transfer membranes.
    offset = membranesOffset;
    for (var membrane in membranes) {
      offset = membrane.transfer(newBuffer, offset);
    }

    // Replace the local buffer.
    buffer = newBuffer;
  }

  /// Get the number of bytes in the render buffer that are allocated by
  /// membranes.
  int get allMembraneBytes {
    int count = 0;
    for (var membrane in membranes) {
      count += membrane.sizeInBytes;
    }
    return count;
  }

  /// Scale buffer so that it can contain the additional number of particles.
  void _rescaleBuffer(int addParticles, int addMembraneBytes) {
    // Check if enough buffer space is available and tranfer data to a larger
    // buffer if neccesary.

    if (addParticles > 0) {
      var finalParticlesOffset = particlesOffset +
          Particle.byteCount * (particles.length + addParticles);
      if (finalParticlesOffset < header.membranesOffset) {
        addParticles = 0;
      }
    }
    if (addMembraneBytes > 0) {
      var finalMembranesOffset =
          header.membranesOffset + allMembraneBytes + addMembraneBytes;
      if (finalMembranesOffset <= buffer.lengthInBytes) {
        addMembraneBytes = 0;
      }
    }

    if (addParticles != 0 || addMembraneBytes != 0) {
      transfer(addParticles, addMembraneBytes);
    }
  }

  /// Update the [bufferHeader] values.
  void updateBufferHeader() {
    header.particleCount = particles.length;
    header.membraneCount = membranes.length;
  }
}
