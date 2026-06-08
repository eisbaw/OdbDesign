// odb_dump - minimal CLI exercising libOdbDesign against an ODB++ archive
// or extracted tree. Validates that the nix-built library actually parses
// real boards, and produces output that can be diff'd against ecad_parse.
//
// Usage:
//   odb-dump <odb-path> [--summary | --by-refdes | --by-net]
//
// <odb-path> can be either a *.tgz archive or an extracted ODB++ job dir;
// FileArchive auto-detects (per upstream behaviour).

#include "OdbDesign.h"
#include "ProductModel/Design.h"
#include "ProductModel/Net.h"
#include "ProductModel/Component.h"
#include "ProductModel/Pin.h"
#include "ProductModel/PinConnection.h"
#include "FileModel/parse_error.h"
#include "FileModel/invalid_odb_error.h"

#include <iostream>
#include <memory>
#include <string>
#include <typeinfo>

using namespace Odb::Lib::ProductModel;

namespace {

const char* side_str(int side) {
    // BoardSide enum: 0=None, 1=Top, 2=Bottom, 3=Both (per enums.h)
    switch (side) {
        case 1: return "T";
        case 2: return "B";
        case 3: return "TB";
        default: return "?";
    }
}

int summary(const std::shared_ptr<Design>& d) {
    const auto& comps = d->GetComponents();
    const auto& nets  = d->GetNets();
    unsigned long total_pins = 0;
    for (const auto& n : nets) total_pins += n->GetPinConnections().size();
    std::cout << "components: " << comps.size() << "\n";
    std::cout << "nets:       " << nets.size()  << "\n";
    std::cout << "pin-conns:  " << total_pins   << "\n";
    return 0;
}

int by_refdes(const std::shared_ptr<Design>& d) {
    for (const auto& c : d->GetComponents()) {
        std::cout << c->GetRefDes()
                  << "  side=" << side_str(static_cast<int>(c->GetSide()))
                  << "  part="  << c->GetPartName()
                  << "\n";
    }
    return 0;
}

int by_net(const std::shared_ptr<Design>& d) {
    for (const auto& n : d->GetNets()) {
        auto& pcs = n->GetPinConnections();
        std::cout << n->GetName() << "  (" << pcs.size() << " pins)\n";
        for (auto& pc : pcs) {
            auto c = pc->GetComponent();
            auto p = pc->GetPin();
            std::cout << "    "
                      << (c ? c->GetRefDes() : "?")
                      << "."
                      << (p ? p->GetName() : "?")
                      << "\n";
        }
    }
    return 0;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 2) {
        std::cerr << "usage: odb-dump <odb-path> [--summary|--by-refdes|--by-net]\n";
        return 2;
    }
    const std::string path = argv[1];
    const std::string mode = (argc >= 3) ? argv[2] : "--summary";

    auto design = std::make_shared<Design>();
    bool ok = false;
    try {
        ok = design->Build(path);
    } catch (const Odb::Lib::FileModel::parse_error& pe) {
        // parse_error::what() returns the constant "Parse error"; the real
        // detail lives in toString() (file + line + token + source location).
        std::cerr << "odb-dump: parse_error during Build(\"" << path << "\"):\n"
                  << pe.toString() << "\n";
        return 1;
    } catch (const Odb::Lib::FileModel::invalid_odb_error& ie) {
        std::cerr << "odb-dump: invalid_odb_error during Build(\"" << path << "\"): "
                  << ie.what() << "\n";
        return 1;
    } catch (const std::exception& e) {
        std::cerr << "odb-dump: std::exception during Build(\"" << path << "\"): "
                  << typeid(e).name() << ": " << e.what() << "\n";
        return 1;
    } catch (...) {
        std::cerr << "odb-dump: non-std exception during Build(\"" << path << "\")\n";
        return 1;
    }
    if (!ok) {
        std::cerr << "odb-dump: Build() returned false for: " << path << "\n";
        return 1;
    }

    if (mode == "--summary")    return summary(design);
    if (mode == "--by-refdes")  return by_refdes(design);
    if (mode == "--by-net")     return by_net(design);

    std::cerr << "odb-dump: unknown mode: " << mode << "\n";
    return 2;
}
